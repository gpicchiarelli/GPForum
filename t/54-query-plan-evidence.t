# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

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

const my $EXPECTED_TESTS     => 47;
const my $DEFAULT_ENDPOINTS  => 13;
const my $RECORDED_ENDPOINTS => 3;

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

my $run_output = q{};
open my $stdout, '>', \$run_output
  or die 'failed to capture query plan evidence output';
{
    local *STDOUT = $stdout;
    is(
        GPForum::Command::QueryPlanEvidence->new->run(
            '--dry-run', '--json', '--endpoint', 'metrics'
        ),
        0,
        'run supports dry-run JSON endpoint selection'
    );
}
close $stdout or die 'failed to close output capture';
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

my $run_ok_output = q{};
open my $run_ok_stdout, '>', \$run_ok_output
  or die 'failed to capture run output';
{
    local *STDOUT = $run_ok_stdout;
    is(
        GPForum::Command::QueryPlanEvidence->new(
            dbh => GPForum::Test::QueryPlanEvidenceDbh->new,
        )->run( '--json', '--no-analyze', '--endpoint', 'home' ),
        0,
        'run executes DB-backed evidence with fake dbh'
    );
}
close $run_ok_stdout or die 'failed to close run output capture';
my $run_ok_report = decode_json($run_ok_output);
is( $run_ok_report->{mode},    'postgres', 'run reports postgres mode' );
is( $run_ok_report->{analyze}, 0,          'run supports no-analyze mode' );

my $profile_output = q{};
open my $profile_stdout, '>', \$profile_output
  or die 'failed to capture profile output';
{
    local *STDOUT = $profile_stdout;
    is(
        GPForum::Command::QueryPlanEvidence->new->run(
            '--dry-run',  '--json', '--profile', 'hot-thread',
            '--endpoint', 'thread_view'
        ),
        0,
        'run supports dataset profile metadata'
    );
}
close $profile_stdout or die 'failed to close profile output capture';
my $profile_report = decode_json($profile_output);
is( $profile_report->{dataset}{profile},
    'hot-thread', 'profile metadata is reflected in JSON' );

my $run_fail_output = q{};
open my $run_fail_stdout, '>', \$run_fail_output
  or die 'failed to capture failing run output';
{
    local *STDOUT = $run_fail_stdout;
    is( $seq_scan_command->run( '--json', '--check', '--endpoint', 'home' ),
        1, 'run returns failure when check sees a violation' );
}
close $run_fail_stdout or die 'failed to close failing output capture';
my $run_fail_report = decode_json($run_fail_output);
is( $run_fail_report->{status}, 'fail', 'run failure JSON reports status' );

my $help_output = q{};
open my $help_stdout, '>', \$help_output
  or die 'failed to capture help output';
{
    local *STDOUT = $help_stdout;
    is( GPForum::Command::QueryPlanEvidence->new->run('--help'),
        0, 'run supports help output' );
}
close $help_stdout or die 'failed to close help output capture';
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

1;
