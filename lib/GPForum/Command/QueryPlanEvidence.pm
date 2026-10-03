# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::QueryPlanEvidence;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json encode_json);
use MIME::Base64  qw(encode_base64url);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Schema;
use GPForum::Service::Clock;
use GPForum::Service::Community::FeedReader;
use GPForum::Service::Forum::CategoryReader;
use GPForum::Service::Forum::PostReader;
use GPForum::Service::Forum::Readability;
use GPForum::Service::Forum::ThreadReader;
use GPForum::Service::Forum::Viewer;
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
const my $GRANTED_CATEGORY_ID   => '018f1001-0002-7000-8000-000000000002';
const my $SPACE_ID              => '018f1000-0001-7000-8000-000000000001';
const my $THREAD_ID             => '018f1004-0001-7000-8000-000000000001';
const my $USER_ID               => '018f1002-0001-7000-8000-000000000001';
const my $PAGE_ROWS             => 26;

# A keyset page costs the same at any depth only if its scan starts at the
# cursor; one that reads its way there filters out every row before it. A
# deep page may filter out a page's worth of rows more than the first page --
# hidden posts, the row equal to the cursor -- and no more. With fewer than
# $DEEP_PAGE_MIN_ROWS rows before the cursor a scan that reads its way there
# hardly exceeds that allowance, and the evidence says so instead of passing
# quietly: the small seed's longest thread has eight posts.
const my $DEPTH_FILTER_SLACK => $PAGE_ROWS;
const my $DEEP_PAGE_MIN_ROWS => 2 * $PAGE_ROWS;

# The deep pages' cursors: the row halfway down the longest thread, the
# largest category and the latest public threads, in each reader's own
# order. Halfway, because a scan that ignores the cursor shows either way
# from there: walking from the top it filters out the first half, fetching
# what follows the cursor it sorts the second. Read outside the plans, once
# per report: the window runs over one thread or one category, though finding
# the longest thread counts every thread's posts.
const my $DEEP_THREAD_SQL => join q{ },
  'WITH longest AS (SELECT thread_id FROM posts GROUP BY thread_id',
  'ORDER BY count(*) DESC, thread_id LIMIT 1),',
  'ranked AS (SELECT p.thread_id, p.position, p.post_id,',
  'row_number() OVER (ORDER BY p.position, p.post_id) AS rank,',
  'count(*) OVER () AS total FROM posts p JOIN longest USING (thread_id))',
  'SELECT r.thread_id, t.category_id, c.space_id, r.position, r.post_id,',
  'r.rank - 1 AS depth FROM ranked r JOIN threads t USING (thread_id)',
  'JOIN categories c ON c.category_id = t.category_id',
  'WHERE r.rank = (r.total + 1) / 2';
const my $DEEP_CATEGORY_SQL => join q{ },
  'WITH largest AS (SELECT category_id FROM threads WHERE deleted_at IS NULL',
  'GROUP BY category_id ORDER BY count(*) DESC, category_id LIMIT 1),',
  'ranked AS (SELECT t.category_id, t.pinned, t.last_activity_at,',
  't.thread_id, row_number() OVER (ORDER BY t.pinned DESC,',
  't.last_activity_at DESC, t.thread_id DESC) AS rank,',
  'count(*) OVER () AS total FROM threads t JOIN largest USING (category_id)',
  'WHERE t.deleted_at IS NULL)',
  'SELECT r.category_id, c.space_id, r.pinned, r.last_activity_at,',
  'r.thread_id, r.rank - 1 AS depth FROM ranked r',
  'JOIN categories c USING (category_id) WHERE r.rank = (r.total + 1) / 2';
const my $DEEP_LATEST_SQL => join q{ },
  'WITH ranked AS (SELECT t.last_activity_at, t.thread_id,',
  'row_number() OVER (ORDER BY t.last_activity_at DESC, t.thread_id DESC)',
  'AS rank, count(*) OVER () AS total FROM threads t',
  q{WHERE t.deleted_at IS NULL AND t.visibility = 'public'},
  q{AND t.moderation_state IN ('visible', 'locked'))},
  'SELECT last_activity_at, thread_id, rank - 1 AS depth FROM ranked',
  'WHERE rank = (total + 1) / 2';

# Each list's cursor, as its reader mints it: PageWindow joins the sort value
# and the id, ThreadReader leads the category's with pinned. Written out here
# because the readers mint cursors only from the rows of a page they fetched;
# a cursor the reader no longer accepts shows as cursor_ignored, not as a
# deep page that passed.
const my %DEEP_PAGE => (
    category => {
        sql    => $DEEP_CATEGORY_SQL,
        cursor => [qw(pinned last_activity_at thread_id)],
    },
    latest => {
        sql    => $DEEP_LATEST_SQL,
        cursor => [qw(last_activity_at thread_id)],
    },
    thread => {
        sql    => $DEEP_THREAD_SQL,
        cursor => [qw(position post_id)],
    },
);
const my $SEARCH_ROWS         => 20;
const my $AUTOCOMPLETE_ROWS   => 10;
const my $CLAIM_ROWS          => 100;
const my $CLAIM_LEASE_SECONDS => 60;
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
  home_signed_in
  home_deep
  category_threads_deep
  category_threads_deep_signed_in
  thread_view_signed_in
  thread_view_deep
  thread_view_deep_signed_in
);

# Tables small by construction, where a sequential scan is the right plan
# whatever the forum's size: categories are created by an administrator.
const my %ALLOWED_SEQ_SCAN_RELATION => map { $_ => 1 }
  qw(schema_versions projection_offsets projection_generations categories);

has dbh    => undef;
has schema => undef;

# The deep pages the report being taken has read, by kind of list: two
# endpoints that page the same list page it at the same cursor.
has deep_pages => sub { return {}; };

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
    $self->deep_pages( {} );
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
            deep_page_filter_rows  => $DEPTH_FILTER_SLACK,
            deep_page_min_rows     => $DEEP_PAGE_MIN_ROWS,
        },
    };
}

sub format_report ( $self, $report, $format ) {
    return encode_json($report) . "\n" if $format eq 'json';

    return _text_report($report);
}

# A deep endpoint EXPLAINs two pages of the same list: the first, and one
# halfway down it. The deep page's plan is judged like any other; the first
# page's is the baseline the deep page's filtering is compared with.
sub _endpoint_report ( $self, $dbh, $endpoint, $options ) {
    my $definition = _endpoint_definition($endpoint);
    my $page       = $self->_deep_page( $dbh, $definition->{deep} );
    my $statement  = $self->_statement( $definition, $page );
    my $first      = $self->_first_page_statement( $definition, $page );
    my $explained  = _explain( $dbh, $statement, $options, $first );
    my $plan       = decode_json( $explained->{plan} )->[0];
    my $analysis   = _analyze_plan( $definition, $statement, $plan );
    _small_table_scans_are_warnings( $dbh, $analysis, $definition );
    push @{ $analysis->{violations} },
      _unindexable( $definition, decode_json( $explained->{forced} )->[0] );
    my $depth =
      $page
      ? _depth_evidence( $dbh, $analysis, $page,
        { deep => $plan, _first_page_plan( $explained, $first, $statement ) } )
      : undef;
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
            ( $depth ? ( depth => $depth ) : () ),
        },
    };
}

# The page a deep endpoint EXPLAINs, read once per report for each kind of
# list; nothing for an endpoint that is not deep.
sub _deep_page ( $self, $dbh, $kind ) {
    return if !defined $kind;

    return $self->deep_pages->{$kind} //= _read_deep_page( $dbh, $kind );
}

# The first page of the list the deep page is in, when there is a deep page.
sub _first_page_statement ( $self, $definition, $page ) {
    return if !$page || !defined $page->{after};

    return $self->_statement( $definition, { %{$page}, after => undef } );
}

# The first page's plan, and whether the reader made the two pages one
# statement.
sub _first_page_plan ( $explained, $first, $statement ) {
    return if !$first;

    return (
        first          => decode_json( $explained->{first} )->[0],
        same_statement => _same_statement( $first, $statement ),
    );
}

# The thread, category or latest thread halfway down, and its cursor. A
# database with nothing to page through gets the seeded ids' first page,
# flagged no_deep_page by _depth_evidence.
sub _read_deep_page ( $dbh, $kind ) {
    my $deep = $DEEP_PAGE{$kind};
    my $row  = $dbh->selectrow_hashref( $deep->{sql} );
    return _seeded_page() if !$row;

    return {
        %{ _seeded_page() },
        %{$row},
        after => encode_base64url(
            join q{|}, map { $_ // q{} } @{$row}{ @{ $deep->{cursor} } }
        ),
        depth => 0 + ( $row->{depth} // 0 ),
    };
}

# Rows Removed by Filter needs ANALYZE; without it the growth is not
# measured, and the evidence says so. A cursor the reader would not decode
# leaves the first page's statement: a deep page that is not one.
sub _depth_evidence ( $dbh, $analysis, $page, $plans ) {
    my $depth = { rows_before_cursor => $page->{depth} };
    if ( !defined $page->{after} ) {
        push @{ $analysis->{warnings} }, 'no_deep_page';
        return $depth;
    }
    if ( $plans->{same_statement} ) {
        push @{ $analysis->{violations} }, 'cursor_ignored';
        return $depth;
    }
    if ( $page->{depth} < $DEEP_PAGE_MIN_ROWS ) {
        push @{ $analysis->{warnings} }, "shallow_page:$page->{depth}";
    }
    if (   !defined $plans->{deep}{Plan}{'Actual Rows'}
        || !defined $plans->{first}{Plan}{'Actual Rows'} )
    {
        push @{ $analysis->{warnings} }, 'filter_growth_unmeasured';
        return $depth;
    }

    my ( $first, $deep ) =
      map { _rows_removed( $dbh, $plans->{$_}{Plan} ) } qw(first deep);
    $depth->{rows_removed_first_page} = $first->{counted};
    $depth->{rows_removed_deep_page}  = $deep->{counted};
    if ( $deep->{counted} - $first->{counted} > $DEPTH_FILTER_SLACK ) {
        push @{ $analysis->{violations} },
          sprintf 'filter_grows_with_depth:%.0f:%.0f', $first->{counted},
          $deep->{counted};
    }
    push @{ $analysis->{warnings} },
      _hidden_growth( $first->{read_whole}, $deep->{read_whole} );

    return $depth;
}

# The rows the page's scans read and threw away, EXPLAIN printing them per
# loop; what small tables read whole threw away is kept apart, by table.
sub _rows_removed ( $dbh, $root ) {
    my $removed = { counted => 0, read_whole => {} };
    _walk_plan(
        $root,
        sub {
            my ($node)   = @_;
            my $loops    = $node->{'Actual Loops'} || 1;
            my $filtered = ( $node->{'Rows Removed by Filter'} // 0 ) * $loops;
            return if !$filtered;
            if ( !_small_table_scan( $dbh, $node, $filtered, $loops ) ) {
                $removed->{counted} += $filtered;
                return;
            }
            my $relation = $node->{'Relation Name'} // q{};
            return if exists $ALLOWED_SEQ_SCAN_RELATION{$relation};
            $removed->{read_whole}{$relation} += $filtered;
        }
    );

    return $removed;
}

# A small table read whole filters out the rows before the cursor too, and
# the planner is right to read it so: the growth is hidden, not absent. The
# medium seed's latest list is read that way with its keyset bound or
# without, so the deep page says it could not tell, as a shallow one does.
# A table filtered alike on both pages -- the signed-in union's arm for the
# reader's own deleted threads -- hides nothing.
sub _hidden_growth ( $first, $deep ) {
    return map { "filter_growth_unmeasured:$_" }
      grep { $deep->{$_} - ( $first->{$_} // 0 ) > $DEPTH_FILTER_SLACK }
      sort keys %{$deep};
}

# A sequential scan of a small table reads all of it whatever the depth --
# the small seed's thread page filters out the other threads' posts on both
# pages -- and is the planner's right answer there. One of a large table
# counts like an index scan: leaving it to the sequential scan rule let a
# deep page through that read a large table to return fewer rows than that
# rule looks at.
sub _small_table_scan ( $dbh, $node, $filtered, $loops ) {
    return 0 if ( $node->{'Node Type'} // q{} ) ne 'Seq Scan';

    my $relation = $node->{'Relation Name'} // q{};
    return 1 if exists $ALLOWED_SEQ_SCAN_RELATION{$relation};

    my $size =
      _relation_size( $dbh, $relation, $filtered + _node_rows($node) * $loops );

    return defined $size && $size <= $SMALL_RELATION_ROWS ? 1 : 0;
}

sub _same_statement ( $first, $second ) {
    return
      join( "\0", map { $_ // q{} } @{$first} ) eq
      join( "\0", map { $_ // q{} } @{$second} ) ? 1 : 0;
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
        my $size = _relation_size( $dbh, $relation, $rows );
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

# The rows the catalog says a table holds, and at least the rows a scan of it
# read; undef for a table the catalog does not know.
sub _relation_size ( $dbh, $relation, $scanned ) {
    my $size = _relation_rows( $dbh, $relation );
    return $size if !defined $size;

    return $size < $scanned ? $scanned : $size;
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
# this gate EXPLAINs. A deep endpoint's resultset takes the page it is
# asked for. Returns [ $sql, @bind ].
sub _statement ( $self, $definition, $page = undef ) {
    return $definition->{statement}->() if $definition->{statement};

    my ( $sql, @bind ) = @{
        ${
            $definition->{resultset}
              ->( $self->_schema, ( $page ? ($page) : () ) )->as_query
        }
    };

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
# Every plan is taken inside a transaction that is rolled back, so gathering
# evidence never changes the data it measures, and SET LOCAL ends with it. A
# deep endpoint's first page is planned there too, before the forced plan.
sub _explain ( $dbh, $statement, $options, $first = undef ) {
    my $flags =
      $options->{analyze}
      ? 'ANALYZE, BUFFERS, FORMAT JSON'
      : 'BUFFERS, FORMAT JSON';
    my ( $sql, @bind ) = @{$statement};

    $dbh->begin_work;
    my $explained = eval {
        my %plans;
        if ($first) {
            my ( $first_sql, @first_bind ) = @{$first};
            $plans{first} =
              $dbh->selectrow_array( "EXPLAIN ($flags) $first_sql",
                undef, @first_bind );
        }
        $plans{plan} =
          $dbh->selectrow_array( "EXPLAIN ($flags) $sql", undef, @bind );
        $dbh->do('SET LOCAL enable_seqscan = off');
        $plans{forced} =
          $dbh->selectrow_array( "EXPLAIN (FORMAT JSON) $sql", undef, @bind );
        return \%plans;
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
                return _latest_threads( $schema, _seeded_page() );
            },
        },
        home_signed_in => {
            purpose   => 'latest public thread listing, member with a grant',
            sql_label => 'threads_public_activity_viewer',
            resultset => sub ($schema) {
                return _latest_threads( $schema, _seeded_page(),
                    _member_viewer() );
            },
        },
        home_deep => {
            purpose   => 'latest public thread listing, halfway down',
            sql_label => 'threads_public_activity_keyset',
            deep      => 'latest',
            resultset => \&_latest_threads,
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
                return _category_threads( $schema, _seeded_page() );
            },
        },
        category_threads_signed_in => {
            purpose   => 'keyset category thread list, signed in',
            sql_label => 'threads_category_viewer_union',
            resultset => sub ($schema) {
                return _category_threads( $schema, _seeded_page(),
                    _member_viewer() );
            },
        },
        category_threads_deep => {
            purpose   => 'keyset category thread list, halfway down',
            sql_label => 'threads_category_activity_keyset',
            deep      => 'category',
            resultset => \&_category_threads,
        },
        category_threads_deep_signed_in => {
            purpose   => 'keyset category thread list, halfway down, signed in',
            sql_label => 'threads_category_viewer_union_keyset',
            deep      => 'category',
            resultset => sub ( $schema, $page ) {
                return _category_threads( $schema, $page, _member_viewer() );
            },
        },
        thread_view => {
            purpose   => 'thread post page with current body',
            sql_label => 'posts_visible_thread_position',
            resultset => sub ($schema) {
                return _thread_posts( $schema, _seeded_page() );
            },
        },
        thread_view_signed_in => {
            purpose   => 'thread post page, signed in',
            sql_label => 'posts_thread_position_viewer',
            resultset => sub ($schema) {
                return _thread_posts( $schema, _seeded_page(),
                    _member_viewer() );
            },
        },
        thread_view_deep => {
            purpose   => 'thread post page halfway down the longest thread',
            sql_label => 'posts_visible_thread_position_keyset',
            deep      => 'thread',
            resultset => \&_thread_posts,
        },
        thread_view_deep_signed_in => {
            purpose =>
              'thread post page halfway down the longest thread, signed in',
            sql_label => 'posts_thread_position_viewer_keyset',
            deep      => 'thread',
            resultset => sub ( $schema, $page ) {
                return _thread_posts( $schema, $page, _member_viewer() );
            },
        },

        # Ordered by relevance over the newest candidate_limit matches only
        # (8.10). For a word most documents hold the planner walks
        # idx_search_documents_created and stops at the cap: at 30,000
        # documents that all hold it, this records no sequential scan and no
        # warning. That needs statistics on categories and spaces (migration
        # 048); without them the planner reads and sorts every match again.
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

# The seeded benchmark ids, without a cursor: the page every list endpoint
# that is not a deep one reads.
sub _seeded_page {
    return {
        after       => undef,
        category_id => $CATEGORY_ID,
        depth       => 0,
        space_id    => $SPACE_ID,
        thread_id   => $THREAD_ID,
    };
}

# The signed-in reader: an account (a member, ADR 0102) with a category.read
# grant on another category than the one paged, as a member with any grant
# usually is. Its conditions carry both branches a member adds -- the
# members' level and their own private rows -- and, on the home page, the
# granted category.
sub _member_viewer {
    return GPForum::Service::Forum::Viewer->new(
        category_ids => [$GRANTED_CATEGORY_ID],
        member       => 1,
        user_id      => $USER_ID,
    );
}

# What HomePageReader asks ThreadReader for.
sub _latest_threads ( $schema, $page, $viewer = undef ) {
    return GPForum::Service::Forum::ThreadReader->new( schema => $schema )
      ->latest_threads_resultset(
        { after => $page->{after}, ( $viewer ? ( viewer => $viewer ) : () ) } );
}

# What Controller::Forum asks ThreadReader for: a signed-in reader adds the
# account and its grants decided for the category.
sub _category_threads ( $schema, $page, $viewer = undef ) {
    return GPForum::Service::Forum::ThreadReader->new( schema => $schema )
      ->category_threads_resultset(
        {
            after       => $page->{after},
            category_id => $page->{category_id},
            _signed_in( $page, $viewer ),
        }
      );
}

# What ThreadDetailReader asks PostReader for, the same way.
sub _thread_posts ( $schema, $page, $viewer = undef ) {
    return GPForum::Service::Forum::PostReader->new( schema => $schema )
      ->thread_posts_resultset(
        {
            after     => $page->{after},
            thread_id => $page->{thread_id},
            _signed_in( $page, $viewer ),
        }
      );
}

sub _signed_in ( $page, $viewer ) {
    return if !$viewer;

    return (
        viewer_scope   => $viewer->within( @{$page}{qw(category_id space_id)} ),
        viewer_user_id => $viewer->user_id,
    );
}

# Search ranks under the configured candidate cap, as the application's does.
# The cap is the inner LIMIT, which decides between walking
# idx_search_documents_created and sorting every match, so evidence taken at
# Searcher's default described a statement a forum with another cap never sent.
sub _searcher ($schema) {
    return GPForum::Service::Search::Searcher->new(
        candidate_limit =>
          GPForum::Config->from_environment->search_candidate_limit,
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
          _depth_text( $endpoint->{summary} ),
          "\n";
    }

    return $text;
}

# How deep a deep endpoint paged and what each page filtered, so a CI log
# shows whether the deep-page rule had anything to measure.
sub _depth_text ($summary) {
    my $depth = $summary ? $summary->{depth} : undef;
    return if !$depth;

    my @text = ( 'depth=' . $depth->{rows_before_cursor} );
    if ( defined $depth->{rows_removed_deep_page} ) {
        push @text, sprintf 'rows_removed=%.0f/%.0f',
          @{$depth}{qw(rows_removed_first_page rows_removed_deep_page)};
    }

    return @text;
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
