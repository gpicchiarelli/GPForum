package main;

use strict;
use warnings;

use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Command::HypnotoadBenchmark;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 34;

plan tests => $EXPECTED_TESTS;

my $command = GPForum::Command::HypnotoadBenchmark->new;

my $json_output = q{};
open my $json_stdout, '>', \$json_output
  or die 'failed to capture hypnotoad benchmark JSON output';
{
    local *STDOUT = $json_stdout;
    is(
        $command->run(
            '--dry-run', '--json', '--profile',    'hot-thread',
            '--workers', '3',      '--iterations', '1',
            '--warmup',  '0',      '--no-compare', '--route',
            '/health/live',
        ),
        0,
        'hypnotoad benchmark dry-run JSON command succeeds'
    );
}
close $json_stdout or die 'failed to close hypnotoad benchmark JSON capture';

my $json_report = decode_json($json_output);
is( $json_report->{mode},   'hypnotoad', 'dry-run reports hypnotoad mode' );
is( $json_report->{status}, 'dry-run',   'dry-run avoids starting server' );
is( $json_report->{dataset}{profile},
    'hot-thread', 'dry-run reports requested profile' );
is( $json_report->{runtime}{workers_requested},
    3, 'dry-run reports requested workers' );
is( $json_report->{routes}[0],
    '/health/live', 'dry-run reports selected route' );
is( $json_report->{comparison}{in_process_enabled},
    0, 'dry-run reports disabled in-process comparison' );

my $text_report = $command->format_report(
    $command->benchmark_report(
        {
            dry_run              => 1,
            compare_in_process   => 1,
            format               => 'text',
            iterations           => 2,
            warmup               => 1,
            profile              => 'small',
            regression_tolerance => 5,
            routes               => ['/metrics'],
            workers              => 2,
            port                 => undef,
        }
    ),
    'text',
);

like( $text_report, qr/mode=hypnotoad/msx, 'text report names hypnotoad mode' );
like( $text_report, qr/status=dry-run/msx, 'text report names dry-run status' );
like( $text_report, qr/workers=2/msx,
    'text report includes configured worker count' );

throws_ok(
    sub {
        $command->run( '--dry-run', '--route', 'not-a-route' );
    },
    qr/Usage/msx,
    'hypnotoad benchmark rejects invalid route'
);

throws_ok(
    sub {
        $command->run( '--dry-run', '--profile', 'huge' );
    },
    qr/Usage/msx,
    'hypnotoad benchmark rejects unknown profile'
);

throws_ok(
    sub {
        $command->run( '--dry-run', '--workers', '0' );
    },
    qr/Usage/msx,
    'hypnotoad benchmark rejects non-positive worker count'
);

my $db_summary = GPForum::Command::HypnotoadBenchmark::_db_query_summary(
    [
        {
            queries             => 2,
            transactions        => 1,
            duplicate_queries   => 0,
            query_budget_status => 'ok',
        },
        {
            queries             => 3,
            transactions        => 1,
            duplicate_queries   => 1,
            query_budget_status => 'fail',
        },
    ]
);
is( $db_summary->{observed},    1, 'DB query summary reports observation' );
is( $db_summary->{max_queries}, 3, 'DB query summary reports max queries' );
is( $db_summary->{budget_status},
    'fail', 'DB query summary reports budget failure precedence' );

my $route_summary = GPForum::Command::HypnotoadBenchmark::_summary(
    '/search?q=performance',
    [ 1, 2, 3 ],
    { 200 => 3 },
    0.006,
    [
        {
            queries             => 1,
            transactions        => 0,
            duplicate_queries   => 0,
            query_budget_status => 'ok',
        }
    ],
);
is( $route_summary->{status}, 'ok', 'route summary passes clean route' );
is( $route_summary->{query_budget},
    'search', 'route summary maps search query budget' );

my $error_route =
  GPForum::Command::HypnotoadBenchmark::_summary( '/health/live', [1],
    { 500 => 1 },
    0.001, [], );
is( $error_route->{status}, 'fail', 'route summary fails HTTP errors' );

my $comparison = GPForum::Command::HypnotoadBenchmark::_compare_route(
    {
        p95_ms      => 3,
        p99_ms      => 4,
        req_per_sec => 2,
    },
    {
        p95_ms      => 1,
        p99_ms      => 1,
        req_per_sec => 10,
    },
    0.5,
);
is( $comparison->{status}, 'fail', 'comparison detects regression' );
ok( @{ $comparison->{violations} },
    'comparison includes regression violations' );

my %runtime_environment =
  GPForum::Command::HypnotoadBenchmark::_runtime_environment(
    {
        accepts    => 100,
        backlog    => 128,
        clients    => 100,
        graceful   => 10,
        inactivity => 30,
        keep_alive => 5,
        workers    => 2,
    },
    5001,
    '/tmp/gpforum-hypnotoad-test.pid',
  );
is( $runtime_environment{GPFORUM_RUNTIME_LISTEN},
    'http://127.0.0.1:5001', 'runtime environment carries listen address' );
is( $runtime_environment{GPFORUM_WEB_PROCESSES},
    2, 'runtime environment carries worker count' );
is( $runtime_environment{GPFORUM_RUNTIME_KEEP_ALIVE_TIMEOUT},
    5, 'runtime environment carries keep-alive timeout' );

is( GPForum::Command::HypnotoadBenchmark::_endpoint_name('/c/category'),
    'category_threads', 'endpoint mapper recognizes category routes' );
is( GPForum::Command::HypnotoadBenchmark::_endpoint_name('/t/thread'),
    'thread_view', 'endpoint mapper recognizes thread routes' );
is(
    GPForum::Command::HypnotoadBenchmark::_endpoint_name(
        '/search/autocomplete?q=per'),
    'search_autocomplete',
    'endpoint mapper recognizes autocomplete routes'
);

{
    local $ENV{GPFORUM_DATABASE_DSN} =
      'dbi:Pg:dbname=gpforum;password=secret;host=127.0.0.1';
    is(
        GPForum::Command::HypnotoadBenchmark::_redacted_dsn(),
        'dbi:Pg:dbname=gpforum;password=REDACTED;host=127.0.0.1',
        'DSN redaction hides password'
    );
}

my $runtime_text = GPForum::Command::HypnotoadBenchmark::_text_report(
    {
        mode       => 'hypnotoad',
        status     => 'ok',
        iterations => 3,
        warmup     => 1,
        dataset    => { profile => 'small' },
        runtime    => {
            workers_requested => 2,
            master_pid        => 123,
            worker_pids       => [ 124, 125 ],
            os_evidence       => {
                status     => 'mismatch',
                event_loop => {
                    declared_backend     => 'kqueue',
                    actual_reactor_class => 'Mojo::Reactor::Poll',
                },
                hypnotoad      => { reuseport_configured => 1 },
                socket_options => { reuseport            => { verified => 1 } },
                static_transfer => { materialized_in_benchmark => 0 },
                postgresql      => { available                 => 1 },
                filesystem      => { df => { mounted_on => '/tmp' } },
            },
        },
        routes => [$route_summary],
    }
);
like( $runtime_text, qr/worker_pids=124,125/msx,
    'text report includes worker PIDs' );
like(
    $runtime_text,
    qr/route=\/search\?q=performance/msx,
    'text report includes measured route'
);
like( $runtime_text, qr/db_queries=max=1/msx,
    'text report includes DB query summary' );
like( $runtime_text, qr/statuses=200:3/msx,
    'text report includes status-code summary' );
like(
    $runtime_text,
    qr/os_evidence_status=mismatch/msx,
    'text report includes OS evidence status'
);
like(
    $runtime_text,
    qr/actual_reactor=Mojo::Reactor::Poll/msx,
    'text report includes actual reactor evidence'
);

1;
