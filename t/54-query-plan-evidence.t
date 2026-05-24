package main;

use strict;
use warnings;

use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::QueryPlanEvidence;
use GPForum::Test::QueryPlanEvidenceDbh;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 26;

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
    10, 'dry-run report lists default evidence endpoints' );
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

throws_ok(
    sub {
        GPForum::Command::QueryPlanEvidence->new->run( '--endpoint',
            'not-real' );
    },
    qr/Usage/msx,
    'run rejects unknown endpoint names before DB access'
);

1;
