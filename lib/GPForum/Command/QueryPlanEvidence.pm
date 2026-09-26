# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::QueryPlanEvidence;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json encode_json);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Schema;
use GPForum::Service::Clock;
use GPForum::Service::Community::FeedReader;
use GPForum::Service::Forum::CategoryReader;
use GPForum::Service::Forum::PostReader;
use GPForum::Service::Forum::Readability;
use GPForum::Service::Forum::ThreadReader;
use GPForum::Service::Moderation::ReportStore;
use GPForum::Service::Notification::Dispatcher;
use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Service::Operations::Readiness;
use GPForum::Service::Outbox::ClaimQuery;
use GPForum::Service::Search::PermissionEngine;
use GPForum::Service::Search::Searcher;

our $VERSION = '0.001';

const my $EXIT_USAGE          => 2;
const my $PLAN_ROWS_SEQ_OK    => 100;
const my $PLAN_ROWS_SORT_OK   => 1_000;
const my $PLAN_ROWS_NESTED_OK => 5_000;

# A sequential scan fails the gate only on a table larger than this. Below
# it a table is a few hundred pages at most, and reading it whole is often
# the planner's right answer: the medium dataset's 120 threads and 1,800 post
# bodies failed the gate on plans that were correct. Whether any index can
# answer the query at all is the forced plan's question, at every size.
const my $SMALL_RELATION_ROWS => 10_000;
const my $RELATION_ROWS_SQL => join q{ },
  q{SELECT greatest(c.reltuples, coalesce(s.n_live_tup, 0))::bigint},
  q{FROM pg_class c LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid},
  q{WHERE c.oid = to_regclass(?)};
const my $SQL_PAGE_SKIP_KEYWORD => join q{}, 'OFF', 'SET';
const my $CATEGORY_ID           => '018f1001-0001-7000-8000-000000000001';
const my $THREAD_ID             => '018f1004-0001-7000-8000-000000000001';
const my $USER_ID               => '018f1002-0001-7000-8000-000000000001';
const my $PAGE_ROWS             => 26;
const my $SEARCH_ROWS           => 20;
const my $AUTOCOMPLETE_ROWS     => 10;
const my $CLAIM_ROWS            => 100;
const my $CLAIM_LEASE_SECONDS   => 60;
const my @DEFAULT_ENDPOINT_NAMES => qw(
  home
  categories
  category_threads
  category_threads_signed_in
  thread_view
  search
  autocomplete
  feed
  notifications outbox_claim
  moderation_queue
  health_ready
  metrics
);

# Tables small by construction, where a sequential scan is the right plan
# whatever the forum's size: categories are created by an administrator.
const my %ALLOWED_SEQ_SCAN_RELATION => map { $_ => 1 }
  qw(schema_versions projection_offsets projection_generations categories);

has dbh    => undef;
has schema => undef;

# A usage croak becomes the documented usage exit instead of an uncaught
# exception: same text, on stderr, status 2, without croak's " at FILE line N".
# Anything else is rethrown, so a real failure is not relabelled as misuse.
sub run ( $self, @arguments ) {
    my $status = eval { return $self->_run(@arguments); };
    return $status if defined $status;

    my $error = GPForum::Command::Usage->trimmed($EVAL_ERROR);
    if ( !GPForum::Command::Usage->is_usage($error) ) {
        die "$error\n";
    }

    return GPForum::Command::Usage->error( undef, $error );
}

sub _run ( $self, @arguments ) {
    my $options = _options(@arguments);
    return _print_usage() if $options->{help};

    my $report = eval { return $self->evidence_report($options); };
    if ( !$report ) {
        print {*STDERR} _db_error($EVAL_ERROR);
        return $EXIT_USAGE;
    }

    print $self->format_report( $report, $options->{format} )
      or croak 'failed to write query plan evidence report';

    return $options->{check} && $report->{status} ne 'ok' ? 1 : 0;
}

sub evidence_report ( $self, $options ) {
    $options->{profile} ||= 'small';
    my @endpoints = _selected_endpoints($options);
    if ( $options->{dry_run} ) {
        return _dry_run_report( \@endpoints, $options );
    }

    my $dbh = $self->_dbh;
    my @reports;
    for my $endpoint (@endpoints) {
        push @reports, $self->_endpoint_report( $dbh, $endpoint, $options );
    }

    return {
        status  => _overall_status( \@reports ),
        mode    => 'postgres',
        analyze => $options->{analyze} ? 1 : 0,
        dsn => _redact_dsn( GPForum::Config->from_environment->database_dsn ),
        endpoints    => \@reports,
        checked_at   => 'runtime',
        dataset      => { profile => $options->{profile} },
        failure_rule => {
            seq_scan_plan_rows     => $PLAN_ROWS_SEQ_OK,
            seq_scan_relation_rows => $SMALL_RELATION_ROWS,
            sort_plan_rows         => $PLAN_ROWS_SORT_OK,
            nested_loop_plan_rows  => $PLAN_ROWS_NESTED_OK,
        },
    };
}

sub format_report ( $self, $report, $format ) {
    return encode_json($report) . "\n" if $format eq 'json';

    return _text_report($report);
}

sub _endpoint_report ( $self, $dbh, $endpoint, $options ) {
    my $definition = _endpoint_definition($endpoint);
    my $statement  = $self->_statement($definition);
    my $explained  = _explain( $dbh, $statement, $options );
    my $plan       = decode_json( $explained->{plan} )->[0];
    my $analysis   = _analyze_plan( $definition, $statement, $plan );
    _small_table_scans_are_warnings( $dbh, $analysis, $definition );
    push @{ $analysis->{violations} },
      _unindexable( $definition, decode_json( $explained->{forced} )->[0] );
    $analysis->{status} = @{ $analysis->{violations} } ? 'fail' : 'ok';

    return {
        endpoint   => $endpoint,
        status     => $analysis->{status},
        purpose    => $definition->{purpose},
        sql_label  => $definition->{sql_label},
        violations => $analysis->{violations},
        warnings   => $analysis->{warnings},
        summary    => {
            root_node      => $plan->{Plan}{'Node Type'},
            plan_rows      => $plan->{Plan}{'Plan Rows'}         || 0,
            actual_rows    => $plan->{Plan}{'Actual Rows'}       || 0,
            total_cost     => $plan->{Plan}{'Total Cost'}        || 0,
            actual_time_ms => $plan->{Plan}{'Actual Total Time'} || 0,
            shared_hit  => _plan_value( $plan->{Plan}, 'Shared Hit Blocks' ),
            shared_read => _plan_value( $plan->{Plan}, 'Shared Read Blocks' ),
        },
    };
}

# A sequential scan is recorded, not failed, when it is the planner's right
# answer: the table is small, or it is the relation a relevance-ordered query
# ranks and the scan returns at least half of it -- a word every document
# holds. Only that relation: the search's joins (its authors, say) are read
# whole by construction, and a latest-first page that reads a whole table to
# sort it is exactly a missing index. An unknown table counts as large; one
# the catalog says holds fewer rows than the scan returned -- never analysed,
# its counters lost -- is at least as large as the scan.
sub _small_table_scans_are_warnings ( $dbh, $analysis, $definition ) {
    my @violations;
    for my $violation ( @{ $analysis->{violations} } ) {
        my ( $relation, $rows ) =
          $violation =~ /\A seq_scan: (.+) : (\d+) \z/msx;
        if ( !defined $relation ) {
            push @violations, $violation;
            next;
        }
        my $size = _relation_rows( $dbh, $relation );
        if ( defined $size && $size < $rows ) {
            $size = $rows;
        }
        if ( defined $size && $size <= $SMALL_RELATION_ROWS ) {
            push @{ $analysis->{warnings} }, "seq_scan_small_table:$relation";
            next;
        }
        if (   defined $size
            && ( $definition->{ranked_relation} // q{} ) eq $relation
            && $rows * 2 >= $size )
        {
            push @{ $analysis->{warnings} }, "seq_scan_most_rows:$relation";
            next;
        }
        push @violations, "seq_scan:$relation";
    }
    $analysis->{violations} = \@violations;

    return;
}

sub _relation_rows ( $dbh, $relation ) {
    my ($rows) = $dbh->selectrow_array( $RELATION_ROWS_SQL, undef, $relation );

    return $rows;
}

sub _dbh ($self) {
    return $self->dbh if $self->dbh;

    return $self->_schema->storage->dbh;
}

# Rendering a resultset's SQL needs the schema but not a connection, so a
# report run against an injected handle still EXPLAINs the application's SQL.
sub _schema ($self) {
    if ( !$self->schema ) {
        $self->schema(
            GPForum::Schema->connect_from_config(
                GPForum::Config->from_environment
            )
        );
    }

    return $self->schema;
}

# What the application executes for the endpoint: the resultset lib/ builds,
# as DBIx::Class renders it, or -- where lib/ issues raw SQL -- lib/'s own
# statement. Nothing is transcribed, so changing a reader's query changes what
# this gate EXPLAINs. Returns [ $sql, @bind ].
sub _statement ( $self, $definition ) {
    return $definition->{statement}->() if $definition->{statement};

    my ( $sql, @bind ) =
      @{ ${ $definition->{resultset}->( $self->_schema )->as_query } };

    return [ $sql, map { ref $_ eq 'ARRAY' ? $_->[1] : $_ } @bind ];
}

# Two plans of the same statement. The first is the planner's own choice,
# which carries the timings and row counts. The second is taken with
# sequential scans disabled: a sequential scan that survives that means no
# index can answer the query at all -- a fact about the schema, true on a
# ten-row test database and on a production one alike, where the first plan's
# row thresholds only notice once the table is already large.
#
# EXPLAIN ANALYZE executes the statement, and the outbox claim is an UPDATE.
# Both plans are taken inside a transaction that is rolled back, so gathering
# evidence never changes the data it measures, and SET LOCAL ends with it.
sub _explain ( $dbh, $statement, $options ) {
    my $flags =
      $options->{analyze}
      ? 'ANALYZE, BUFFERS, FORMAT JSON'
      : 'BUFFERS, FORMAT JSON';
    my ( $sql, @bind ) = @{$statement};

    $dbh->begin_work;
    my $explained = eval {
        my $plan =
          $dbh->selectrow_array( "EXPLAIN ($flags) $sql", undef, @bind );
        $dbh->do('SET LOCAL enable_seqscan = off');
        my $forced =
          $dbh->selectrow_array( "EXPLAIN (FORMAT JSON) $sql", undef, @bind );
        return { plan => $plan, forced => $forced };
    };
    my $error = $EVAL_ERROR;
    $dbh->rollback;
    croak $error if !$explained;

    return $explained;
}

sub _unindexable ( $definition, $forced ) {
    return if $definition->{allow_seq_scan};

    my @relations;
    _walk_plan(
        $forced->{Plan},
        sub {
            my ($node) = @_;
            my $relation = $node->{'Relation Name'} || q{};
            if ( ( $node->{'Node Type'} || q{} ) eq 'Seq Scan'
                && !exists $ALLOWED_SEQ_SCAN_RELATION{$relation} )
            {
                push @relations, $relation;
            }
        }
    );

    return map { "no_usable_index:$_" } @relations;
}

sub _analyze_plan {
    my ( $definition, $statement, $plan ) = @_;

    my @warnings;
    my @violations;
    _walk_plan(
        $plan->{Plan},
        sub {
            my ($node) = @_;
            push @violations, _node_violations( $definition, $node );
            push @warnings,   _node_warnings($node);
        }
    );
    if ( $statement->[0] =~ /\b \Q$SQL_PAGE_SKIP_KEYWORD\E \b/imsx ) {
        push @violations, 'offset_in_hot_query';
    }

    return {
        status     => @violations ? 'fail' : 'ok',
        violations => \@violations,
        warnings   => \@warnings,
    };
}

sub _node_violations ( $definition, $node ) {
    my @violations;
    my $type     = $node->{'Node Type'}     || q{};
    my $relation = $node->{'Relation Name'} || q{};
    my $rows     = _node_rows($node);

    if ( $type eq 'Seq Scan'
        && !_seq_scan_allowed( $definition, $relation, $rows ) )
    {
        # Actual Rows is an average per loop, printed with decimals: a
        # parallel scan's workers each read a share of the table.
        my $scanned =
            $node->{'Parallel Aware'}
          ? $rows * ( $node->{'Actual Loops'} || 1 )
          : $rows;
        push @violations, sprintf 'seq_scan:%s:%.0f', $relation, $scanned;
    }
    if ( $type eq 'Sort' && $rows > $PLAN_ROWS_SORT_OK ) {
        push @violations, 'heavy_sort:' . $rows;
    }
    if (   $type eq 'Nested Loop'
        && $rows > $PLAN_ROWS_NESTED_OK
        && _node_rows( _outer_child($node) ) > 1 )
    {
        # A loop over one outer row -- the one space a search joins -- is a
        # join against a constant, however many rows it passes through.
        push @violations, 'explosive_nested_loop:' . $rows;
    }

    return @violations;
}

# The outer side of a join. EXPLAIN lists a node's InitPlans before its
# outer and inner children, so it is found by role, not by position.
sub _outer_child ($node) {
    my @children = @{ $node->{Plans} || [] };
    my ($outer) =
      grep { ( $_->{'Parent Relationship'} // q{} ) eq 'Outer' } @children;

    return $outer || $children[0] || {};
}

sub _node_warnings ($node) {
    my @warnings;
    my $type = $node->{'Node Type'} || q{};

    push @warnings, 'bitmap_heap_scan'
      if $type eq 'Bitmap Heap Scan'
      && _node_rows($node) > $PLAN_ROWS_SORT_OK;

    return @warnings;
}

sub _seq_scan_allowed ( $definition, $relation, $rows ) {
    return 1 if exists $ALLOWED_SEQ_SCAN_RELATION{$relation};
    return 1 if $definition->{allow_seq_scan};
    return 1 if $rows <= $PLAN_ROWS_SEQ_OK;

    return 0;
}

sub _node_rows ($node) {
    return $node->{'Actual Rows'} if defined $node->{'Actual Rows'};
    return $node->{'Plan Rows'}   if defined $node->{'Plan Rows'};

    return 0;
}

sub _walk_plan ( $node, $visitor ) {
    return if !$node;

    $visitor->($node);
    for my $child ( @{ $node->{Plans} || [] } ) {
        _walk_plan( $child, $visitor );
    }

    return;
}

sub _plan_value ( $plan, $name ) {
    return 0 if !defined $plan->{$name};

    return $plan->{$name};
}

sub _dry_run_report ( $endpoints, $options ) {
    return {
        status    => 'ok',
        mode      => 'dry-run',
        analyze   => $options->{analyze} ? 1 : 0,
        dataset   => { profile => $options->{profile} },
        endpoints => [
            map {
                my $definition = _endpoint_definition($_);
                {
                    endpoint   => $_,
                    status     => 'ok',
                    purpose    => $definition->{purpose},
                    sql_label  => $definition->{sql_label},
                    violations => [],
                    warnings   => [],
                }
            } @{$endpoints}
        ],
    };
}

sub _endpoint_definition ($endpoint) {
    my %definitions = (
        home => {
            purpose   => 'latest public thread listing',
            sql_label => 'threads_public_activity',
            resultset => sub ($schema) {
                return GPForum::Service::Forum::ThreadReader->new(
                    schema => $schema )->latest_threads_resultset( {} );
            },
        },
        categories => {
            purpose   => 'category index',
            sql_label => 'categories_position',
            resultset => sub ($schema) {
                return GPForum::Service::Forum::CategoryReader->new(
                    schema => $schema )->categories_resultset($PAGE_ROWS);
            },
        },
        category_threads => {
            purpose   => 'keyset category thread list, anonymous',
            sql_label => 'threads_category_activity_visible_locked',
            resultset => sub ($schema) {
                return GPForum::Service::Forum::ThreadReader->new(
                    schema => $schema )
                  ->category_threads_resultset(
                    { category_id => $CATEGORY_ID } );
            },
        },
        category_threads_signed_in => {
            purpose   => 'keyset category thread list, signed in',
            sql_label => 'threads_category_viewer_union',
            resultset => sub ($schema) {
                return GPForum::Service::Forum::ThreadReader->new(
                    schema => $schema )
                  ->category_threads_resultset(
                    { category_id => $CATEGORY_ID, viewer_user_id => $USER_ID }
                  );
            },
        },
        thread_view => {
            purpose   => 'thread post page with current body',
            sql_label => 'posts_visible_thread_position',
            resultset => sub ($schema) {
                return GPForum::Service::Forum::PostReader->new(
                    schema => $schema )
                  ->thread_posts_resultset( { thread_id => $THREAD_ID } );
            },
        },

        # Ordered by relevance: every match is scored before the first page
        # is known, so a word most documents hold is read in full.
        search => {
            purpose         => 'permission-safe PostgreSQL search projection',
            ranked_relation => 'search_documents',
            sql_label       => 'search_documents_vector',
            resultset       => sub ($schema) {
                return _searcher($schema)
                  ->search_resultset( undef,
                    'performance', { limit => $SEARCH_ROWS } );
            },
        },
        autocomplete => {
            purpose => 'permission-safe PostgreSQL autocomplete projection',
            ranked_relation => 'search_documents',
            sql_label       => 'search_documents_title_trgm',
            resultset       => sub ($schema) {
                return _searcher($schema)
                  ->autocomplete_resultset( undef,
                    'perf', { limit => $AUTOCOMPLETE_ROWS } );
            },
        },
        feed => {
            purpose   => 'user feed projection',
            sql_label => 'user_feed_items_user_created',
            resultset => sub ($schema) {
                return GPForum::Service::Community::FeedReader->new(
                    readability => _readability($schema),
                    schema      => $schema,
                )->feed_resultset( $USER_ID, { limit => $PAGE_ROWS } );
            },
        },
        notifications => {
            purpose   => 'notification inbox page',
            sql_label => 'notification_inbox_recipient_created',
            resultset => sub ($schema) {
                return GPForum::Service::Notification::Dispatcher->new(
                    readability => _readability($schema),
                    schema      => $schema,
                )->inbox_resultset( $USER_ID, { limit => $PAGE_ROWS } );
            },
        },
        moderation_queue => {
            purpose   => 'moderation report queue',
            sql_label => 'reports_queue',
            resultset => sub ($schema) {
                return GPForum::Service::Moderation::ReportStore->new(
                    schema => $schema )
                  ->queue_resultset( { limit => $PAGE_ROWS } );
            },
        },

        # A one-row read of the event log, the largest table readiness
        # touches. A sequential scan cut at one row is the cheapest answer.
        health_ready => {
            purpose        => 'readiness table probe',
            sql_label      => 'readiness_event_log_probe',
            allow_seq_scan => 1,
            resultset      => sub ($schema) {
                return GPForum::Service::Operations::Readiness->new(
                    schema => $schema )->probe_resultset('EventLog');
            },
        },
        metrics => {
            purpose   => 'outbox retry backlog metric',
            sql_label => 'outbox_retry_backlog',
            resultset => sub ($schema) {
                return GPForum::Service::Operations::MetricsSnapshot->new(
                    schema => $schema )->retry_backlog_resultset->count_rs;
            },
        },
        outbox_claim => {
            purpose   => 'outbox worker ready-claim scan',
            sql_label => 'outbox_claim_ready',
            statement => \&_claim_statement,
        },
    );

    croak _usage() if !exists $definitions{$endpoint};

    return $definitions{$endpoint};
}

# The feed and the inbox filter on what the benchmark user can read, as they
# do in the application.
sub _readability ($schema) {
    return GPForum::Service::Forum::Readability->new( schema => $schema );
}

sub _searcher ($schema) {
    return GPForum::Service::Search::Searcher->new(
        permission_engine =>
          GPForum::Service::Search::PermissionEngine->new( schema => $schema ),
        schema => $schema,
    );
}

# The claim is raw SQL in lib/, so it is taken from there with the binds a
# worker would send.
sub _claim_statement {
    my $clock = GPForum::Service::Clock->new;
    my $claim = GPForum::Service::Outbox::ClaimQuery->new;

    return [
        $claim->sql,
        @{
            $claim->bind_values(
                {
                    limit        => $CLAIM_ROWS,
                    locked_until =>
                      $clock->epoch_plus_iso8601($CLAIM_LEASE_SECONDS),
                    now       => $clock->now_iso8601,
                    worker_id => 'query-plan-evidence',
                }
            )
        }
    ];
}

sub _selected_endpoints ($options) {
    return @{ $options->{endpoints} }
      ? @{ $options->{endpoints} }
      : @DEFAULT_ENDPOINT_NAMES;
}

sub _overall_status ($reports) {
    for my $report ( @{$reports} ) {
        return 'fail' if $report->{status} ne 'ok';
    }

    return 'ok';
}

sub _text_report ($report) {
    my $text =
        'query_plan_evidence status='
      . $report->{status}
      . ' mode='
      . $report->{mode}
      . ' analyze='
      . $report->{analyze}
      . ' dataset_profile='
      . $report->{dataset}{profile} . "\n";

    for my $endpoint ( @{ $report->{endpoints} } ) {
        $text .= join q{ },
          'endpoint=' . $endpoint->{endpoint},
          'status=' . $endpoint->{status},
          'sql_label=' . $endpoint->{sql_label},
          'violations=' . _list_text( $endpoint->{violations} ),
          'warnings=' . _list_text( $endpoint->{warnings} ),
          "\n";
    }

    return $text;
}

sub _list_text ($values) {
    return 'none' if !@{$values};

    return join q{,}, @{$values};
}

sub _options (@arguments) {
    my $options = {
        analyze   => 1,
        check     => 0,
        dry_run   => 0,
        endpoints => [],
        format    => 'text',
        help      => 0,
        profile   => 'small',
    };

    while (@arguments) {
        _consume_option( $options, \@arguments );
    }

    return $options;
}

sub _consume_option ( $options, $arguments ) {
    my $argument = shift @{$arguments};
    my %handler  = (
        '--check'      => sub { $options->{check}   = 1; },
        '--analyze'    => sub { $options->{analyze} = 1; },
        '--dry-run'    => sub { $options->{dry_run} = 1; },
        '--json'       => sub { $options->{format}  = 'json'; },
        '--help'       => sub { $options->{help}    = 1; },
        '--no-analyze' => sub { $options->{analyze} = 0; },
        '--endpoint'   => sub {
            push @{ $options->{endpoints} },
              _endpoint_name( shift @{$arguments} );
        },
        '--profile' => sub {
            $options->{profile} = _profile( shift @{$arguments} );
        },
    );

    my $handler = $handler{$argument};
    croak _usage() if !$handler;
    $handler->();

    return;
}

sub _endpoint_name ($value) {
    my %known = map { $_ => 1 } @DEFAULT_ENDPOINT_NAMES;
    croak _usage() if !defined $value || !$known{$value};

    return $value;
}

sub _profile ($value) {
    croak _usage()
      if !defined $value
      || ( $value ne 'small'
        && $value ne 'medium'
        && $value ne 'hot-thread' );

    return $value;
}

sub _print_usage {
    print _usage(), "\n" or croak 'failed to write usage';

    return 0;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return
        'Usage: '
      . GPForum::Command::Usage->program
      . ' [--dry-run] [--json] [--check] [--analyze] [--no-analyze] [--profile small|medium|hot-thread] [--endpoint NAME] ...';
}

sub _db_error ($error) {
    return
        'script/query-plan-evidence: PostgreSQL query plan evidence failed. '
      . 'Run script/bootstrap-deps --postgres, apply migrations, '
      . 'seed benchmark data, and ensure the database is reachable. Error: '
      . $error;
}

sub _redact_dsn ($dsn) {
    $dsn =~ s/(password=)[^;]+/${1}<redacted>/gmsx;

    return $dsn;
}

1;
