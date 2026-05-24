package main;

use strict;
use warnings;

use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Command::HypnotoadScaling;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 19;

plan tests => $EXPECTED_TESTS;

my $command = GPForum::Command::HypnotoadScaling->new;

my $json_output = q{};
open my $json_stdout, '>', \$json_output
  or die 'failed to capture hypnotoad scaling JSON output';
{
    local *STDOUT = $json_stdout;
    is(
        $command->run(
            '--dry-run',    '--json',
            '--profile',    'hot-thread',
            '--worker-set', '2,4,8',
            '--iterations', '1',
            '--warmup',     '0',
            '--route',      '/categories',
            '--route',      '/t/018f1004-0001-7000-8000-000000000001',
        ),
        0,
        'hypnotoad scaling dry-run JSON command succeeds'
    );
}
close $json_stdout or die 'failed to close hypnotoad scaling JSON capture';

my $json_report = decode_json($json_output);
is( $json_report->{mode}, 'hypnotoad-scaling', 'dry-run reports scaling mode' );
is( $json_report->{status}, 'dry-run',         'dry-run keeps dry-run status' );
is( $json_report->{dataset}{profile},
    'hot-thread', 'dry-run reports requested profile' );
is_deeply( $json_report->{workers}, [ 2, 4, 8 ], 'dry-run reports worker set' );
is( scalar @{ $json_report->{reports} },
    3, 'dry-run includes one report per worker count' );
is( $json_report->{reports}[0]{runtime}{workers_requested},
    2, 'first worker report uses 2 workers' );
is( $json_report->{reports}[1]{runtime}{workers_requested},
    4, 'second worker report uses 4 workers' );
is( $json_report->{reports}[2]{runtime}{workers_requested},
    8, 'third worker report uses 8 workers' );
is(
    $json_report->{routes}[1],
    '/t/018f1004-0001-7000-8000-000000000001',
    'dry-run keeps real thread route'
);

my $text_report = $command->format_report(
    $command->scaling_report(
        {
            accepts              => 100,
            backlog              => 128,
            check                => 0,
            clients              => 100,
            compare_in_process   => 0,
            dry_run              => 1,
            format               => 'text',
            graceful             => 10,
            inactivity           => 30,
            iterations           => 2,
            keep_alive           => 5,
            profile              => 'small',
            regression_tolerance => 5,
            routes               => ['/search?q=performance'],
            seed                 => 0,
            warmup               => 1,
            worker_counts        => [ 2, 4 ],
        }
    ),
    'text',
);

like( $text_report, qr/mode=hypnotoad-scaling/msx,
    'text report names scaling mode' );
like( $text_report, qr/workers=2,4/msx, 'text report includes worker set' );
like(
    $text_report,
    qr/worker_set [ ] workers=2/msx,
    'text report includes first worker set block'
);
like(
    $text_report,
    qr/worker_set [ ] workers=4/msx,
    'text report includes second worker set block'
);

throws_ok(
    sub {
        $command->run( '--dry-run', '--worker-set', '2,nope' );
    },
    qr/Usage/msx,
    'hypnotoad scaling rejects invalid worker set'
);

throws_ok(
    sub {
        $command->run( '--dry-run', '--profile', 'massive' );
    },
    qr/Usage/msx,
    'hypnotoad scaling rejects unknown profile'
);

throws_ok(
    sub {
        $command->run( '--dry-run', '--route', 'not-a-route' );
    },
    qr/Usage/msx,
    'hypnotoad scaling rejects invalid route'
);

my $failing_report = GPForum::Command::HypnotoadScaling::_overall_status(
    [ { status => 'ok' }, { status => 'fail' }, ] );
is( $failing_report, 'fail', 'overall scaling status detects failures' );

my $clean_report = GPForum::Command::HypnotoadScaling::_overall_status(
    [ { status => 'ok' }, { status => 'ok' }, ] );
is( $clean_report, 'ok', 'overall scaling status passes clean reports' );

1;
