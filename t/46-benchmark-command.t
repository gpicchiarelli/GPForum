package main;

use strict;
use warnings;

use Const::Fast;
use File::Temp    qw(tempfile);
use JSON::MaybeXS qw(decode_json encode_json);
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Command::Benchmark;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 26;
const my $HTTP_OK        => 200;
const my $HTTP_NOT_FOUND => 404;

plan tests => $EXPECTED_TESTS;

my $command     = GPForum::Command::Benchmark->new;
my $text_report = $command->benchmark_report(
    '--fixture', '--iterations', '2',            '--warmup',
    '1',         '--route',      '/health/live', '--route',
    '/categories',
);
my $text = $command->format_report( $text_report, 'text' );

like( $text, qr/mode=fixture/msx, 'benchmark text reports fixture mode' );
like( $text, qr/route=\/health\/live/msx,
    'benchmark text reports health route' );
like( $text, qr/route=\/categories/msx,
    'benchmark text reports categories route' );
like( $text, qr/p95_ms=/msx, 'benchmark text reports p95 latency' );
like(
    $text,
    qr/query_budget=categories:3/msx,
    'benchmark text reports query budget contract'
);
like(
    $text,
    qr/db_queries=not-observed/msx,
    'benchmark text reports unobserved DB query state'
);
like( $text, qr/statuses=200:2/msx, 'benchmark text reports status counts' );

my $json_report = $command->benchmark_report(
    '--fixture', '--json', '--iterations', '1',
    '--warmup',  '0',      '--route',      '/search?q=welcome',
);
my $json_text = $command->format_report( $json_report, 'json' );
my $report    = decode_json($json_text);
is( $report->{mode},       'fixture', 'benchmark JSON reports fixture mode' );
is( $report->{iterations}, 1,         'benchmark JSON reports iterations' );
is( $report->{routes}[0]{route},
    '/search?q=welcome', 'benchmark JSON reports route' );
is( $report->{routes}[0]{status_codes}{$HTTP_OK},
    1, 'benchmark JSON reports status map' );
is( $report->{routes}[0]{query_budget}{max_queries},
    2, 'benchmark JSON reports query budget contract' );
is( $report->{routes}[0]{db_queries}{observed},
    0, 'benchmark JSON reports DB query observation state' );

my $error_report =
  $command->benchmark_report( '--fixture', '--iterations', '1', '--warmup',
    '0', '--route', '/missing-benchmark-route', );
is( $error_report->{status}, 'fail', 'benchmark fails HTTP errors' );
is( $error_report->{routes}[0]{status_codes}{$HTTP_NOT_FOUND},
    1, 'benchmark records HTTP error status counts' );

my ( $baseline_handle, $baseline_path ) = tempfile();
print {$baseline_handle} $json_text or die 'failed to write baseline';
close $baseline_handle              or die 'failed to close baseline';

my $baseline_report =
  $command->benchmark_report( '--fixture', '--iterations', '1', '--warmup',
    '0', '--route', '/search?q=welcome', '--baseline',
    $baseline_path, '--regression-tolerance', '100', );
is( $baseline_report->{routes}[0]{regression}{status},
    'ok', 'benchmark compares route against saved baseline' );

my ( $write_handle, $write_path ) = tempfile();
close $write_handle or die 'failed to close writable baseline';
my $run_output = q{};
open my $capture, '>', \$run_output or die 'failed to capture benchmark output';
{
    local *STDOUT = $capture;
    is(
        $command->run(
            '--fixture',        '--json', '--iterations', '1',
            '--warmup',         '0',      '--route',      '/health',
            '--write-baseline', $write_path,
        ),
        0,
        'benchmark writes saved baseline through command run'
    );
}
close $capture or die 'failed to close benchmark output capture';
like( $run_output, qr/"status":"ok"/msx,
    'benchmark run emits JSON report while writing baseline' );
ok( -s $write_path, 'benchmark saved baseline file is written' );

my ( $strict_handle, $strict_path ) = tempfile();
print {$strict_handle} encode_json(
    {
        routes => [
            {
                route       => '/search?q=welcome',
                p95_ms      => 0.001,
                p99_ms      => 0.001,
                req_per_sec => 1_000_000,
            },
        ],
    }
) or die 'failed to write strict baseline';
close $strict_handle or die 'failed to close strict baseline';

my $strict_report =
  $command->benchmark_report( '--fixture', '--iterations', '1', '--warmup',
    '0', '--route', '/search?q=welcome', '--baseline',
    $strict_path, '--regression-tolerance', '0.01', );
is( $strict_report->{status},
    'fail', 'benchmark fails on saved baseline regression' );
is( $strict_report->{routes}[0]{regression}{status},
    'fail', 'benchmark reports route-level regression failure' );
ok(
    @{ $strict_report->{routes}[0]{regression}{violations} },
    'benchmark includes regression violation details'
);

my ( $missing_handle, $missing_path ) = tempfile();
print {$missing_handle} encode_json( { routes => [] } )
  or die 'failed to write missing baseline';
close $missing_handle or die 'failed to close missing baseline';

my $missing_report = $command->benchmark_report(
    '--fixture', '--iterations', '1',                 '--warmup',
    '0',         '--route',      '/search?q=welcome', '--baseline',
    $missing_path,
);
is( $missing_report->{status},
    'fail', 'benchmark fails when route is missing from saved baseline' );
is( $missing_report->{routes}[0]{regression}{status},
    'missing', 'benchmark reports missing route baseline' );

throws_ok(
    sub {
        $command->run( '--iterations', '0' );
    },
    qr/Usage/msx,
    'benchmark rejects invalid iterations'
);

throws_ok(
    sub {
        $command->run( '--route', 'relative' );
    },
    qr/Usage/msx,
    'benchmark rejects relative routes'
);

1;
