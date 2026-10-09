# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::QueryPlanEvidence;
use GPForum::Service::Forum::ThreadReader;
use GPForum::Service::Outbox::ClaimQuery;
use GPForum::Test::QueryPlanEvidenceDbh;

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;

const my $EXPECTED_TESTS        => 69;
const my $DEFAULT_ENDPOINTS     => 20;
const my $RECORDED_ENDPOINTS    => 3;
const my $CONFIGURED_CANDIDATES => 300;
const my $PAGE_ROWS             => 26;
const my $UNION_ARMS            => 2;
const my $GROWN_PER_LOOP        => $PAGE_ROWS * $UNION_ARMS;
const my $DEEP_DEPTH            => 499;
const my $SHALLOW_DEPTH         => 10;
const my $SMALL_TABLE_ROWS      => 3_000;
const my $DEEP_POST_ID          => '018f1005-01f4-7000-8000-0000000001f4';
const my $DEEP_THREAD_ID        => '018f1004-0007-7000-8000-000000000007';
const my $GRANTED_CATEGORY_ID   => '018f1001-0002-7000-8000-000000000002';
const my $MEMBER_ID             => '018f1002-0001-7000-8000-000000000001';

# The rows the deep-page queries find, as DBD::Pg returns them: strings, and
# booleans as 1 and 0.
const my %DEEP_THREAD => (
    category_id => '018f1001-0001-7000-8000-000000000001',
    depth       => "$DEEP_DEPTH",
    position    => '500',
    post_id     => $DEEP_POST_ID,
    space_id    => '018f1000-0001-7000-8000-000000000001',
    thread_id   => $DEEP_THREAD_ID,
);
const my %DEEP_CATEGORY => (
    category_id      => '018f1001-0003-7000-8000-000000000003',
    depth            => '300',
    last_activity_at => '2026-05-24 09:52:00+00',
    pinned           => '0',
    space_id         => '018f1000-0001-7000-8000-000000000001',
    thread_id        => '018f1004-012d-7000-8000-00000000012d',
);

plan tests => $EXPECTED_TESTS;

my $ok_command = GPForum::Command::QueryPlanEvidence->new(
    dbh => GPForum::Test::QueryPlanEvidenceDbh->new, );
my $ok_report = $ok_command->evidence_report(
    {
        analyze   => 0,
        dry_run   => 0,
        endpoints => ['home'],
    }
);
is( $ok_report->{status}, 'ok', 'index-backed fake plan passes evidence' );
is( $ok_report->{endpoints}[0]{summary}{root_node},
    'Index Scan', 'query evidence reports root node' );

my $seq_scan_command = GPForum::Command::QueryPlanEvidence->new(
    dbh => GPForum::Test::QueryPlanEvidenceDbh->new(
        plan => {
            Plan => {
                'Node Type'     => 'Seq Scan',
                'Relation Name' => 'threads',
                'Plan Rows'     => 250,
                'Actual Rows'   => 250,
                'Total Cost'    => 100,
            },
        },
    ),
);
my $seq_report = $seq_scan_command->evidence_report(
    {
        analyze   => 0,
        dry_run   => 0,
        endpoints => ['home'],
    }
);
is( $seq_report->{status}, 'fail', 'large seq scan fails evidence gate' );
is( $seq_report->{endpoints}[0]{violations}[0],
    'seq_scan:threads', 'seq scan violation names relation' );

# The same scan of a table the catalog says is small is the planner's right
# answer: recorded as a warning, not failed.
my $small_report = GPForum::Command::QueryPlanEvidence->new(
    dbh => GPForum::Test::QueryPlanEvidenceDbh->new(
        forced_plan => {
            Plan => {
                'Node Type'     => 'Index Scan',
                'Relation Name' => 'threads',
                'Plan Rows'     => 250,
            },
        },
        plan          => $seq_scan_command->dbh->plan,
        relation_rows => 120,
    ),
)->evidence_report( { analyze => 0, dry_run => 0, endpoints => ['home'] } );
is( $small_report->{status},
    'ok', 'a seq scan of a small table passes the gate' );
is_deeply(
    $small_report->{endpoints}[0]{warnings},
    ['seq_scan_small_table:threads'],
    'and is recorded as a warning'
);

my $decoded = decode_json( $ok_command->format_report( $ok_report, 'json' ) );
is( $decoded->{endpoints}[0]{status},
    'ok', 'query evidence JSON remains machine readable' );

my $sort_command = GPForum::Command::QueryPlanEvidence->new(
    dbh => GPForum::Test::QueryPlanEvidenceDbh->new(
        plan => {
            Plan => {
                'Node Type'   => 'Limit',
                'Plan Rows'   => 1_500,
                'Actual Rows' => 1_500,
                'Plans'       => [
                    {
                        'Node Type'   => 'Sort',
                        'Plan Rows'   => 1_500,
                        'Actual Rows' => 1_500,
                    },
                ],
            },
        },
    ),
);
my $sort_report = $sort_command->evidence_report(
    {
        analyze   => 0,
        dry_run   => 0,
        endpoints => ['home'],
    }
);
is( $sort_report->{status}, 'fail', 'large sort fails evidence gate' );
is( $sort_report->{endpoints}[0]{violations}[0],
    'heavy_sort:1500', 'sort violation records row pressure' );

my $allowed_seq = GPForum::Command::QueryPlanEvidence->new(
    dbh => GPForum::Test::QueryPlanEvidenceDbh->new(
        plan => {
            Plan => {
                'Node Type'     => 'Seq Scan',
                'Relation Name' => 'projection_offsets',
                'Plan Rows'     => 5_000,
                'Actual Rows'   => 5_000,
            },
        },
    ),
);
my $allowed_report = $allowed_seq->evidence_report(
    {
        analyze   => 0,
        dry_run   => 0,
        endpoints => ['metrics'],
    }
);
is( $allowed_report->{status}, 'ok',
    'small metadata seq scans can be allowed' );

my $dry_run = GPForum::Command::QueryPlanEvidence->new->evidence_report(
    {
        analyze   => 1,
        dry_run   => 1,
        endpoints => [],
    }
);
is( $dry_run->{mode}, 'dry-run', 'dry-run report avoids PostgreSQL' );
is( scalar @{ $dry_run->{endpoints} },
    $DEFAULT_ENDPOINTS, 'dry-run report lists default evidence endpoints' );
like(
    GPForum::Command::QueryPlanEvidence->new->format_report( $dry_run, 'text' ),
    qr/query_plan_evidence [ ] status=ok/msx,
    'text report remains human readable'
);

my ( $run_status, $run_output ) =
  _run_capturing( GPForum::Command::QueryPlanEvidence->new,
    '--dry-run', '--json', '--endpoint', 'metrics' );
is( $run_status, 0, 'run supports dry-run JSON endpoint selection' );
my $run_report = decode_json($run_output);
is( $run_report->{endpoints}[0]{endpoint},
    'metrics', 'run endpoint selection is reflected in JSON' );

my $autocomplete = GPForum::Command::QueryPlanEvidence->new->evidence_report(
    {
        analyze   => 1,
        dry_run   => 1,
        endpoints => ['autocomplete'],
    }
);
is( $autocomplete->{endpoints}[0]{sql_label},
    'search_documents_title_trgm', 'autocomplete evidence uses trigram index' );
is( $autocomplete->{endpoints}[0]{status},
    'ok', 'autocomplete evidence participates in dry-run gate' );

throws_ok(
    sub {
        GPForum::Command::QueryPlanEvidence->new(
            dbh => GPForum::Test::QueryPlanEvidenceDbh->new, )
          ->evidence_report(
            {
                analyze   => 0,
                dry_run   => 0,
                endpoints => ['missing'],
            }
          );
    },
    qr/Usage/msx,
    'unknown endpoint is rejected'
);

my ( $run_ok_status, $run_ok_output ) = _run_capturing(
    GPForum::Command::QueryPlanEvidence->new(
        dbh => GPForum::Test::QueryPlanEvidenceDbh->new,
    ),
    '--json',
    '--no-analyze',
    '--endpoint',
    'home'
);
is( $run_ok_status, 0, 'run executes DB-backed evidence with fake dbh' );
my $run_ok_report = decode_json($run_ok_output);
is( $run_ok_report->{mode},    'postgres', 'run reports postgres mode' );
is( $run_ok_report->{analyze}, 0,          'run supports no-analyze mode' );

my ( $profile_status, $profile_output ) =
  _run_capturing( GPForum::Command::QueryPlanEvidence->new,
    '--dry-run',  '--json', '--profile', 'hot-thread',
    '--endpoint', 'thread_view' );
is( $profile_status, 0, 'run supports dataset profile metadata' );
my $profile_report = decode_json($profile_output);
is( $profile_report->{dataset}{profile},
    'hot-thread', 'profile metadata is reflected in JSON' );

my ( $run_fail_status, $run_fail_output ) =
  _run_capturing( $seq_scan_command, '--json', '--check', '--endpoint',
    'home' );
is( $run_fail_status, 1, 'run returns failure when check sees a violation' );
my $run_fail_report = decode_json($run_fail_output);
is( $run_fail_report->{status}, 'fail', 'run failure JSON reports status' );

my ( $help_status, $help_output ) =
  _run_capturing( GPForum::Command::QueryPlanEvidence->new, '--help' );
is( $help_status, 0, 'run supports help output' );
like( $help_output, qr/query-plan-evidence/msx,
    'help output names the script' );

my $bitmap_command = GPForum::Command::QueryPlanEvidence->new(
    dbh => GPForum::Test::QueryPlanEvidenceDbh->new(
        plan => {
            Plan => {
                'Node Type'   => 'Bitmap Heap Scan',
                'Plan Rows'   => 1_500,
                'Actual Rows' => 1_500,
            },
        },
    ),
);
my $bitmap_report = $bitmap_command->evidence_report(
    {
        analyze   => 0,
        dry_run   => 0,
        endpoints => ['home'],
    }
);
is( $bitmap_report->{status}, 'ok', 'large bitmap heap scan is a warning' );
is( $bitmap_report->{endpoints}[0]{warnings}[0],
    'bitmap_heap_scan', 'bitmap heap scan warning is explicit' );

my $nested_command = GPForum::Command::QueryPlanEvidence->new(
    dbh => GPForum::Test::QueryPlanEvidenceDbh->new(
        plan => {
            Plan => {
                'Node Type'   => 'Nested Loop',
                'Plan Rows'   => 6_000,
                'Actual Rows' => 6_000,
                'Plans'       => [
                    { 'Node Type' => 'Index Scan', 'Actual Rows' => 60 },
                    { 'Node Type' => 'Index Scan', 'Actual Rows' => 100 },
                ],
            },
        },
    ),
);
my $nested_report = $nested_command->evidence_report(
    {
        analyze   => 0,
        dry_run   => 0,
        endpoints => ['home'],
    }
);
is( $nested_report->{status}, 'fail', 'large nested loop fails evidence gate' );
is(
    $nested_report->{endpoints}[0]{violations}[0],
    'explosive_nested_loop:6000',
    'nested loop violation records row pressure'
);

# A loop over a single outer row is a join against a constant, however many
# rows pass through it: the one space a search joins.
my %one_row_outer = (
    'Node Type'   => 'Nested Loop',
    'Actual Rows' => 6_000,
    'Plans'       => [
        { 'Node Type' => 'Seq Scan',  'Actual Rows' => 1, },
        { 'Node Type' => 'Hash Join', 'Actual Rows' => 6_000 },
    ],
);
is(
    GPForum::Command::QueryPlanEvidence->new(
        dbh => GPForum::Test::QueryPlanEvidenceDbh->new(
            forced_plan => { Plan => { 'Node Type' => 'Index Scan' } },
            plan        => { Plan => \%one_row_outer },
        )
    )->evidence_report(
        { analyze => 0, dry_run => 0, endpoints => ['home'] }
    )->{status},
    'ok',
    'a nested loop over one outer row is not explosive'
);

# A relevance-ordered query must score every match, so a scan returning at
# least half of a large table is its right plan -- a search for a word every
# document holds. A latest-first page reading the whole table to sort it is
# a missing index, and still fails.
my %whole_table = (
    forced_plan => { Plan => { 'Node Type' => 'Bitmap Heap Scan' } },
    plan        => {
        Plan => {
            'Node Type'     => 'Seq Scan',
            'Relation Name' => 'search_documents',
            'Actual Rows'   => 20_000,
        },
    },
    relation_rows => 20_000,
);
my %status_of = map { $_ => _status( \%whole_table, $_ ) } qw(search home);
is(
    $status_of{search},
    'ok seq_scan_most_rows:search_documents',
    'a search reading most of a large table is a warning'
);
is(
    $status_of{home},
    'fail seq_scan:search_documents',
    'a latest-first page reading the whole table is not'
);

# Only the ranked relation earns it: a search's authors are read whole by
# construction, so a full scan of a large users table still fails.
is(
    _status(
        {
            %whole_table,
            plan => {
                Plan => {
                    'Node Type'     => 'Seq Scan',
                    'Relation Name' => 'users',
                    'Actual Rows'   => 20_000,
                },
            },
        },
        'search'
    ),
    'fail seq_scan:users',
    'a search reading every user still fails'
);

# A parallel scan reports rows per worker, with decimals: the whole scan is
# what is compared with the table.
is(
    _status(
        {
            %whole_table,
            plan => {
                Plan => {
                    'Node Type'      => 'Seq Scan',
                    'Relation Name'  => 'search_documents',
                    'Parallel Aware' => JSON::MaybeXS::true(),
                    'Actual Rows'    => 10_000.33,
                    'Actual Loops'   => 3,
                },
            },
            relation_rows => 30_000,
        },
        'search'
    ),
    'ok seq_scan_most_rows:search_documents',
    'a parallel scan is judged by all its workers\' rows'
);

# A table the catalog says is empty -- never analysed -- is at least as large
# as what its scan returned.
is(
    _status( { %whole_table, relation_rows => 0 }, 'home' ),
    'fail seq_scan:search_documents',
    'missing statistics do not make a large scan small'
);

# run() answers misuse with the documented exit status; evidence_report(),
# asserted above, is a library method and still throws.
is(
    _usage_status(
        sub {
            return GPForum::Command::QueryPlanEvidence->new->run( '--endpoint',
                'not-real' );
        }
    ),
    $EXIT_USAGE,
    'run rejects unknown endpoint names before DB access'
);

my $outbox_claim = GPForum::Command::QueryPlanEvidence->new->evidence_report(
    {
        analyze   => 1,
        dry_run   => 1,
        endpoints => ['outbox_claim'],
    }
);
is( $outbox_claim->{endpoints}[0]{sql_label},
    'outbox_claim_ready', 'outbox claim evidence has a dedicated label' );
like(
    $outbox_claim->{endpoints}[0]{purpose},
    qr/outbox [ ] worker/msx,
    'outbox claim evidence documents worker claim intent'
);
is( $outbox_claim->{endpoints}[0]{status},
    'ok', 'outbox claim evidence participates in dry-run gate' );

# A small sequential scan passes the row-count rule, and on a test-sized
# database every scan is small. The second plan, taken with sequential scans
# disabled, still shows it: no index can answer the query, whatever the size.
{
    my $small_scan = GPForum::Command::QueryPlanEvidence->new(
        dbh => GPForum::Test::QueryPlanEvidenceDbh->new(
            plan => {
                Plan => {
                    'Node Type'     => 'Seq Scan',
                    'Relation Name' => 'threads',
                    'Plan Rows'     => 10,
                },
            },
        ),
      )
      ->evidence_report(
        { analyze => 0, dry_run => 0, endpoints => ['category_threads'] } );
    is_deeply(
        $small_scan->{endpoints}[0]{violations},
        ['no_usable_index:threads'],
        'a sequential scan no index could replace fails at any table size'
    );
}

# The gate EXPLAINs what the application runs, not a transcription of it: the
# statement for an endpoint is the SQL its reader renders, byte for byte, and
# the outbox claim is the claim query's own SQL.
{
    my $recording = GPForum::Test::QueryPlanEvidenceDbh->new;
    my $command = GPForum::Command::QueryPlanEvidence->new( dbh => $recording );
    $command->evidence_report(
        {
            analyze   => 1,
            dry_run   => 0,
            endpoints => [qw(home category_threads_signed_in outbox_claim)],
        }
    );
    my ( $home, $signed_in, $claim ) =
      grep { $_->{sql} =~ /\A EXPLAIN [ ] [(] ANALYZE/msx }
      @{ $recording->statements };

    my ($reader_sql) = @{
        ${ GPForum::Service::Forum::ThreadReader->new(
                schema => $command->schema
            )->latest_threads_resultset( {} )->as_query
        }
    };
    like( $home->{sql}, qr/\Q$reader_sql\E\z/msx,
        'the home endpoint EXPLAINs the SQL ThreadReader executes' );
    like(
        $signed_in->{sql},
        qr/UNION [ ] ALL/msx,
        'the signed-in category endpoint EXPLAINs the reader\'s union'
    );
    like(
        $claim->{sql},
        qr/\Q${\ GPForum::Service::Outbox::ClaimQuery->sql }\E\z/msx,
        'the outbox claim endpoint EXPLAINs the claim query itself'
    );

    # EXPLAIN ANALYZE runs the statement, and the claim is an UPDATE.
    is_deeply(
        $recording->transactions,
        [ ( 'begin', 'rollback' ) x $RECORDED_ENDPOINTS ],
        'every plan is taken in a transaction that is rolled back'
    );
}

# Search ranks the newest GPFORUM_SEARCH_CANDIDATE_LIMIT matches, and that
# inner LIMIT decides between walking the newest-first index and sorting every
# match. The gate EXPLAINs the cap the application is configured with, not
# Searcher's default.
{
    local $ENV{GPFORUM_SEARCH_CANDIDATE_LIMIT} = $CONFIGURED_CANDIDATES;
    my $recording = GPForum::Test::QueryPlanEvidenceDbh->new;
    GPForum::Command::QueryPlanEvidence->new( dbh => $recording )
      ->evidence_report(
        {
            analyze   => 0,
            dry_run   => 0,
            endpoints => ['search'],
        }
      );
    my ($search) =
      grep { $_->{sql} =~ /\A EXPLAIN/msx } @{ $recording->statements };
    is( scalar( grep { $_ eq $CONFIGURED_CANDIDATES } @{ $search->{bind} } ),
        1, 'the search endpoint EXPLAINs the configured candidate cap' );
}

# Deep pages. The first page of a list proves nothing about its hundredth: a
# keyset predicate the index cannot start from reads every row before the
# cursor and filters it out. A deep endpoint EXPLAINs the page halfway down
# the longest thread (or the largest category, or the latest threads) and
# its first page, and fails when the deep one filters out more than a page's
# worth of rows the first one did not.
{
    my $recording = GPForum::Test::QueryPlanEvidenceDbh->new(
        deep_page => {%DEEP_THREAD},
        plans     => [ _removed_plan(0), _removed_plan(2) ],
    );
    my $report = _deep_report( $recording, 'thread_view_deep' );
    is( $report->{status}, 'ok',
        'a deep page that starts at its cursor passes' );
    is_deeply(
        $report->{summary}{depth},
        {
            rows_before_cursor      => $DEEP_DEPTH,
            rows_removed_first_page => 0,
            rows_removed_deep_page  => 2,
        },
        'and the evidence records how deep it was and what each page filtered'
    );
    like(
        GPForum::Command::QueryPlanEvidence->new->format_report(
            {
                analyze   => 1,
                dataset   => { profile => 'small' },
                endpoints => [$report],
                mode      => 'postgres',
                status    => 'ok',
            },
            'text'
        ),
        qr/depth=$DEEP_DEPTH [ ] rows_removed=0\/2/msx,
        'which the text report shows too'
    );
    my ( $first, $deep ) = grep { $_->{sql} =~ /\A EXPLAIN [ ] [(] ANALYZE/msx }
      @{ $recording->statements };
    is_deeply(
        [ map { _binds( $_, $DEEP_POST_ID ) } $first, $deep ],
        [ 0,                                          1 ],
        'the deep page is the reader\'s own statement past the cursor'
    );
    is( _binds( $deep, $DEEP_THREAD_ID ),
        1, 'in the longest thread the database holds' );
}

is(
    _deep_status(
        { plans => [ _removed_plan(0), _removed_plan($DEEP_DEPTH) ] },
        'thread_view_deep'
    ),
    "fail filter_grows_with_depth:0:$DEEP_DEPTH",
    'a deep page that filters out every row before its cursor fails'
);
is(
    _deep_status(
        {
            plans => [
                _removed_plan( 0,          $UNION_ARMS ),
                _removed_plan( $PAGE_ROWS, $UNION_ARMS ),
            ]
        },
        'thread_view_deep'
    ),
    "fail filter_grows_with_depth:0:$GROWN_PER_LOOP",
    'rows removed are counted over every loop, as EXPLAIN prints them per loop'
);

# A sequential scan of a small table reads all of it whatever the depth: what
# it filters out is not growth. But when it filters out the rows before the
# cursor, the growth is hidden, not absent -- the medium seed's latest list
# is read so with its keyset bound or without -- and the evidence says it
# could not tell. On a large table it is growth, even when the scan returns
# too few rows for the sequential scan rule to notice it.
is(
    _deep_status(
        { _seq_scan_deep_page(), relation_rows => $SMALL_TABLE_ROWS },
        'thread_view_deep'
    ),
    'ok filter_growth_unmeasured:posts',
    'a sequential scan of a small table is not counted as growth, but said'
);
is(
    _deep_status(
        {
            plans => [
                _seq_scan_plan( 'posts', $DEEP_DEPTH ),
                _seq_scan_plan( 'posts', $DEEP_DEPTH + 2 ),
            ],
            relation_rows => $SMALL_TABLE_ROWS,
        },
        'thread_view_deep'
    ),
    'ok',
    'and one that filters alike on both pages hides nothing'
);
is(
    _deep_status( { _seq_scan_deep_page() }, 'thread_view_deep' ),
    "fail filter_grows_with_depth:0:$DEEP_DEPTH",
    'one of a large table that reads its way to the cursor fails'
);
is( _deep_status( { _seq_scan_deep_page('categories') }, 'thread_view_deep' ),
    'ok', 'and one of a table small by construction is never growth' );

# A cursor the reader does not accept shows its first page: a deep page that
# is not one fails, rather than passing on the first page's plan.
is(
    _deep_status(
        { deep_page => { %DEEP_THREAD, position => 'not-a-position' } },
        'thread_view_deep'
    ),
    'fail cursor_ignored',
    'a cursor the reader ignores fails the deep page'
);
is(
    _deep_status( { deep_page => undef }, 'thread_view_deep' ),
    'ok no_deep_page',
    'a database with nothing to page through says so'
);
is(
    _deep_status(
        { deep_page => { %DEEP_THREAD, depth => $SHALLOW_DEPTH } },
        'thread_view_deep'
    ),
    "ok shallow_page:$SHALLOW_DEPTH",
    'and so does one whose longest list is too short to tell'
);
is(
    _deep_status(
        { plans => [], plan => { Plan => { 'Node Type' => 'Index Scan' } } },
        'thread_view_deep'
    ),
    'ok filter_growth_unmeasured',
    'without ANALYZE the filtering is not measured, and the evidence says so'
);

# Every kind of deep list pages with its reader's own cursor, read once per
# report however many endpoints page it.
{
    my $recording =
      GPForum::Test::QueryPlanEvidenceDbh->new( deep_page => {%DEEP_CATEGORY} );
    my $command = GPForum::Command::QueryPlanEvidence->new( dbh => $recording );
    my $report  = $command->evidence_report(
        {
            analyze   => 1,
            dry_run   => 0,
            endpoints =>
              [qw(category_threads_deep category_threads_deep_signed_in)],
        }
    );
    is_deeply( [ map { $_->{status} } @{ $report->{endpoints} } ],
        [qw(ok ok)], 'the category\'s deep pages pass with its pinned cursor' );
    is(
        scalar(
            grep { $_->{sql} =~ /\A WITH/msx } @{ $recording->statements }
        ),
        1,
        'and the deep page is read once for both'
    );
    my @deep = grep {
        $_->{sql} =~ /\A EXPLAIN [ ] [(] ANALYZE/msx
          && _binds( $_, $DEEP_CATEGORY{thread_id} )
    } @{ $recording->statements };
    is( scalar @deep, 2, 'each EXPLAINs the reader\'s statement past it' );
    like(
        $deep[1]{sql},
        qr/UNION [ ] ALL/msx,
        'the signed-in one through the reader\'s union'
    );
}

# Signed in: a member with a category.read grant, as the application passes
# it, so the plans cover the conditions a member adds.
{
    my $recording = GPForum::Test::QueryPlanEvidenceDbh->new;
    GPForum::Command::QueryPlanEvidence->new( dbh => $recording )
      ->evidence_report(
        {
            analyze   => 0,
            dry_run   => 0,
            endpoints => [qw(home_signed_in thread_view_signed_in)],
        }
      );
    my ( $home, $thread ) =
      grep { $_->{sql} =~ /\A EXPLAIN [ ] [(] BUFFERS/msx }
      @{ $recording->statements };
    is( _binds( $home, $GRANTED_CATEGORY_ID ),
        2, 'the signed-in home page reads the granted category' );
    is(
        _binds( $thread, $MEMBER_ID ),
        2,
        'and the signed-in thread the member\'s own deleted and private posts'
    );
}

# How many of a recorded statement's binds are the value.
sub _binds {
    my ( $statement, $value ) = @_;

    return scalar grep { $_ eq $value } @{ $statement->{bind} };
}

sub _removed_plan {
    my ( $removed, $loops ) = @_;

    return {
        Plan => {
            'Node Type'   => 'Limit',
            'Actual Rows' => $PAGE_ROWS,
            'Plans'       => [
                {
                    'Node Type'              => 'Index Scan',
                    'Relation Name'          => 'posts',
                    'Actual Rows'            => $PAGE_ROWS,
                    'Actual Loops'           => $loops // 1,
                    'Rows Removed by Filter' => $removed,
                },
            ],
        },
    };
}

# The deep page read by a sequential scan that filters out every row before
# the cursor; fresh plans each time, since the double answers them in turn.
sub _seq_scan_deep_page {
    my ($relation) = @_;

    return (
        plans => [
            _removed_plan(0),
            _seq_scan_plan( $relation // 'posts', $DEEP_DEPTH )
        ]
    );
}

sub _seq_scan_plan {
    my ( $relation, $removed ) = @_;

    return {
        Plan => {
            'Node Type'              => 'Seq Scan',
            'Relation Name'          => $relation,
            'Actual Rows'            => $PAGE_ROWS,
            'Rows Removed by Filter' => $removed,
        },
    };
}

sub _deep_report {
    my ( $dbh, $endpoint ) = @_;

    return GPForum::Command::QueryPlanEvidence->new( dbh => $dbh )
      ->evidence_report(
        { analyze => 1, dry_run => 0, endpoints => [$endpoint] } )
      ->{endpoints}[0];
}

sub _deep_status {
    my ( $dbh_input, $endpoint ) = @_;

    my $report = _deep_report(
        GPForum::Test::QueryPlanEvidenceDbh->new(
            deep_page => {%DEEP_THREAD},
            plans     => [ _removed_plan(0), _removed_plan(0) ],
            %{$dbh_input},
        ),
        $endpoint
    );

    return join q{ }, $report->{status}, @{ $report->{warnings} },
      @{ $report->{violations} };
}

sub _usage_status {
    my ($code) = @_;

    my $errors = q{};
    open my $capture, '>', \$errors or croak 'capture stderr';
    my $status;
    {
        local *STDERR = $capture;
        $status = $code->();
    }
    close $capture or croak 'close stderr';
    like( $errors, qr/Usage/msx, 'the usage text goes to stderr' );

    return $status;
}

sub _status {
    my ( $dbh_input, $endpoint ) = @_;

    my $report =
      GPForum::Command::QueryPlanEvidence->new(
        dbh => GPForum::Test::QueryPlanEvidenceDbh->new( %{$dbh_input} ) )
      ->evidence_report(
        { analyze => 0, dry_run => 0, endpoints => [$endpoint] } );

    return join q{ }, $report->{status},
      @{ $report->{endpoints}[0]{warnings} },
      @{ $report->{endpoints}[0]{violations} };
}

# Runs the command with its standard output captured: ( exit status, output ).
sub _run_capturing {
    my ( $command, @arguments ) = @_;

    my $output = q{};
    open my $stdout, '>', \$output or croak 'failed to capture command output';
    my $status = do {
        local *STDOUT = $stdout;
        $command->run(@arguments);
    };
    close $stdout or croak 'failed to close output capture';

    return ( $status, $output );
}

1;
