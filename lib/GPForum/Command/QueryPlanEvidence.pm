package GPForum::Command::QueryPlanEvidence;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json encode_json);
use Mojo::Base -base;

use GPForum::Config;
use GPForum::Schema;

our $VERSION = '0.001';

const my $EXIT_USAGE            => 2;
const my $PLAN_ROWS_SEQ_OK      => 100;
const my $PLAN_ROWS_SORT_OK     => 1_000;
const my $PLAN_ROWS_NESTED_OK   => 5_000;
const my $SQL_PAGE_SKIP_KEYWORD => join q{}, 'OFF', 'SET';
const my $SPACE_ID              => '018f1000-0001-7000-8000-000000000001';
const my $CATEGORY_ID           => '018f1001-0001-7000-8000-000000000001';
const my $THREAD_ID             => '018f1004-0001-7000-8000-000000000001';
const my $USER_ID               => '018f1002-0001-7000-8000-000000000001';
const my @DEFAULT_ENDPOINT_NAMES => qw(
  home
  categories
  category_threads
  thread_view
  search
  autocomplete
  feed
  notifications
  moderation_queue
  health_ready
  metrics
);
const my %ALLOWED_SEQ_SCAN_RELATION => map { $_ => 1 }
  qw(schema_versions projection_offsets projection_generations);

has dbh    => undef;
has schema => undef;

sub run {
    my ( $self, @arguments ) = @_;

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

sub evidence_report {
    my ( $self, $options ) = @_;

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
            seq_scan_plan_rows    => $PLAN_ROWS_SEQ_OK,
            sort_plan_rows        => $PLAN_ROWS_SORT_OK,
            nested_loop_plan_rows => $PLAN_ROWS_NESTED_OK,
        },
    };
}

sub format_report {
    my ( $self, $report, $format ) = @_;

    return encode_json($report) . "\n" if $format eq 'json';

    return _text_report($report);
}

sub _endpoint_report {
    my ( $self, $dbh, $endpoint, $options ) = @_;

    my $definition = _endpoint_definition($endpoint);
    my $json       = _explain_json( $dbh, $definition, $options );
    my $plan       = decode_json($json)->[0];
    my $analysis   = _analyze_plan( $definition, $plan );

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

sub _dbh {
    my ($self) = @_;

    return $self->dbh if $self->dbh;

    my $schema = $self->schema;
    if ( !$schema ) {
        my $config = GPForum::Config->from_environment;
        $schema = GPForum::Schema->connect_from_config($config);
    }

    return $schema->storage->dbh;
}

sub _explain_json {
    my ( $dbh, $definition, $options ) = @_;

    my $flags =
      $options->{analyze}
      ? 'ANALYZE, BUFFERS, FORMAT JSON'
      : 'BUFFERS, FORMAT JSON';
    my $sql = 'EXPLAIN (' . $flags . ') ' . $definition->{sql};

    return $dbh->selectrow_array( $sql, undef, @{ $definition->{bind} } );
}

sub _analyze_plan {
    my ( $definition, $plan ) = @_;

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
    push @violations, 'offset_in_hot_query'
      if $definition->{sql} =~ /\b \Q$SQL_PAGE_SKIP_KEYWORD\E \b/imsx;

    return {
        status     => @violations ? 'fail' : 'ok',
        violations => \@violations,
        warnings   => \@warnings,
    };
}

sub _node_violations {
    my ( $definition, $node ) = @_;

    my @violations;
    my $type     = $node->{'Node Type'}     || q{};
    my $relation = $node->{'Relation Name'} || q{};
    my $rows     = _node_rows($node);

    if ( $type eq 'Seq Scan'
        && !_seq_scan_allowed( $definition, $relation, $rows ) )
    {
        push @violations, 'seq_scan:' . $relation;
    }
    if ( $type eq 'Sort' && $rows > $PLAN_ROWS_SORT_OK ) {
        push @violations, 'heavy_sort:' . $rows;
    }
    if ( $type eq 'Nested Loop' && $rows > $PLAN_ROWS_NESTED_OK ) {
        push @violations, 'explosive_nested_loop:' . $rows;
    }

    return @violations;
}

sub _node_warnings {
    my ($node) = @_;

    my @warnings;
    my $type = $node->{'Node Type'} || q{};

    push @warnings, 'bitmap_heap_scan'
      if $type eq 'Bitmap Heap Scan'
      && _node_rows($node) > $PLAN_ROWS_SORT_OK;

    return @warnings;
}

sub _seq_scan_allowed {
    my ( $definition, $relation, $rows ) = @_;

    return 1 if exists $ALLOWED_SEQ_SCAN_RELATION{$relation};
    return 1 if $definition->{allow_seq_scan};
    return 1 if $rows <= $PLAN_ROWS_SEQ_OK;

    return 0;
}

sub _node_rows {
    my ($node) = @_;

    return $node->{'Actual Rows'} if defined $node->{'Actual Rows'};
    return $node->{'Plan Rows'}   if defined $node->{'Plan Rows'};

    return 0;
}

sub _walk_plan {
    my ( $node, $visitor ) = @_;

    return if !$node;

    $visitor->($node);
    for my $child ( @{ $node->{Plans} || [] } ) {
        _walk_plan( $child, $visitor );
    }

    return;
}

sub _plan_value {
    my ( $plan, $name ) = @_;

    return 0 if !defined $plan->{$name};

    return $plan->{$name};
}

sub _dry_run_report {
    my ( $endpoints, $options ) = @_;

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

sub _endpoint_definition {
    my ($endpoint) = @_;

    my %definitions = (
        home => {
            purpose   => 'latest public thread listing',
            sql_label => 'threads_public_activity',
            sql       => q{
                SELECT thread_id, category_id, title, slug, last_activity_at
                  FROM threads
                 WHERE deleted_at IS NULL
                   AND visibility = 'public'
                   AND moderation_state IN ('visible', 'locked')
                 ORDER BY last_activity_at DESC, thread_id DESC
                 LIMIT 26
            },
            bind => [],
        },
        categories => {
            purpose   => 'category list for public space',
            sql_label => 'categories_space_position',
            sql       => q{
                SELECT category_id, slug, title, position
                  FROM categories
                 WHERE space_id = ?
                   AND deleted_at IS NULL
                   AND visibility = 'public'
                 ORDER BY position ASC, category_id ASC
                 LIMIT 25
            },
            bind => [$SPACE_ID],
        },
        category_threads => {
            purpose   => 'keyset category thread list',
            sql_label => 'threads_category_activity_visible_locked',
            sql       => q{
                SELECT thread_id, title, slug, last_activity_at
                  FROM threads
                 WHERE category_id = ?
                   AND deleted_at IS NULL
                   AND moderation_state IN ('visible', 'locked')
                 ORDER BY pinned DESC, last_activity_at DESC, thread_id DESC
                 LIMIT 26
            },
            bind => [$CATEGORY_ID],
        },
        thread_view => {
            purpose   => 'thread post page with current body',
            sql_label => 'posts_visible_thread_position',
            sql       => q{
                SELECT p.post_id, p.position, p.author_user_id,
                       b.body_rendered_safe
                  FROM posts p
                  JOIN post_bodies b ON b.body_id = p.current_body_id
                 WHERE p.thread_id = ?
                   AND p.deleted_at IS NULL
                   AND p.moderation_state = 'visible'
                 ORDER BY p.position ASC, p.post_id ASC
                 LIMIT 51
            },
            bind => [$THREAD_ID],
        },
        search => {
            purpose   => 'permission-safe PostgreSQL search projection',
            sql_label => 'search_documents_vector',
            sql       => q{
                SELECT entity_type, entity_id, title, indexed_at,
                       ts_rank_cd(
                           search_vector,
                           websearch_to_tsquery('simple', ?),
                           32
                       ) AS rank_score
                  FROM search_documents
                 WHERE visibility = 'public'
                   AND permission_scope = 'public'
                   AND search_vector @@ websearch_to_tsquery('simple', ?)
                 ORDER BY rank_score DESC, indexed_at DESC, entity_id DESC
                 LIMIT 20
            },
            bind => [ 'performance', 'performance' ],
        },
        autocomplete => {
            purpose   => 'permission-safe PostgreSQL autocomplete projection',
            sql_label => 'search_documents_title_trgm',
            sql       => q{
                SELECT entity_type, entity_id, title
                  FROM search_documents
                 WHERE visibility = 'public'
                   AND permission_scope = 'public'
                   AND title_normalized LIKE ?
                 ORDER BY title_normalized ASC
                 LIMIT 10
            },
            bind => ['performance%'],
        },
        feed => {
            purpose   => 'user feed projection',
            sql_label => 'user_feed_items_user_created',
            sql       => q{
                SELECT user_id, item_type, item_id, created_at, rank_score
                  FROM user_feed_items
                 WHERE user_id = ?
                 ORDER BY created_at DESC, item_id DESC
                 LIMIT 26
            },
            bind => [$USER_ID],
        },
        notifications => {
            purpose   => 'notification inbox page',
            sql_label => 'notification_inbox_recipient_created',
            sql       => q{
                SELECT i.recipient_user_id, i.notification_id, i.created_at,
                       i.read_at, i.rank_score, n.notification_type, n.payload
                  FROM notification_inbox i
                  JOIN notifications n
                    ON n.notification_id = i.notification_id
                   AND n.created_at = i.created_at
                 WHERE i.recipient_user_id = ?
                 ORDER BY i.created_at DESC, i.notification_id DESC
                 LIMIT 26
            },
            bind => [$USER_ID],
        },
        moderation_queue => {
            purpose   => 'moderation report queue',
            sql_label => 'reports_queue',
            sql       => q{
                SELECT report_id, reporter_user_id, target_type, target_id,
                       reason, status, created_at
                  FROM reports
                 WHERE status IN ('open', 'triaged')
                 ORDER BY created_at ASC, report_id ASC
                 LIMIT 26
            },
            bind => [],
        },
        health_ready => {
            purpose        => 'readiness schema probe',
            sql_label      => 'readiness_regclass',
            allow_seq_scan => 1,
            sql            => q{
                SELECT to_regclass('public.event_log') AS event_log,
                       to_regclass('public.outbox_messages') AS outbox_messages,
                       to_regclass('public.projection_generations')
                         AS projection_generations
            },
            bind => [],
        },
        metrics => {
            purpose   => 'outbox pending metric',
            sql_label => 'outbox_ready',
            sql       => q{
                SELECT count(*) AS pending
                  FROM outbox_messages
                 WHERE status IN ('pending', 'failed')
                   AND next_attempt_at <= now()
            },
            bind => [],
        },
    );

    croak _usage() if !exists $definitions{$endpoint};

    return $definitions{$endpoint};
}

sub _selected_endpoints {
    my ($options) = @_;

    return @{ $options->{endpoints} }
      ? @{ $options->{endpoints} }
      : @DEFAULT_ENDPOINT_NAMES;
}

sub _overall_status {
    my ($reports) = @_;

    for my $report ( @{$reports} ) {
        return 'fail' if $report->{status} ne 'ok';
    }

    return 'ok';
}

sub _text_report {
    my ($report) = @_;

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

sub _list_text {
    my ($values) = @_;

    return 'none' if !@{$values};

    return join q{,}, @{$values};
}

sub _options {
    my (@arguments) = @_;

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

sub _consume_option {
    my ( $options, $arguments ) = @_;

    my $argument = shift @{$arguments};
    my %handler  = (
        '--check'      => sub { $options->{check}   = 1; },
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

sub _endpoint_name {
    my ($value) = @_;

    my %known = map { $_ => 1 } @DEFAULT_ENDPOINT_NAMES;
    croak _usage() if !defined $value || !$known{$value};

    return $value;
}

sub _profile {
    my ($value) = @_;

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

sub _usage {
    return
'Usage: script/query-plan-evidence [--dry-run] [--json] [--check] [--no-analyze] [--profile small|medium|hot-thread] [--endpoint NAME] ...';
}

sub _db_error {
    my ($error) = @_;

    return
        'script/query-plan-evidence: PostgreSQL query plan evidence failed. '
      . 'Run script/bootstrap-deps --postgres, apply migrations, '
      . 'seed benchmark data, and ensure the database is reachable. Error: '
      . $error;
}

sub _redact_dsn {
    my ($dsn) = @_;

    $dsn =~ s/(password=)[^;]+/${1}<redacted>/gmsx;

    return $dsn;
}

1;
