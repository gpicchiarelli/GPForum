package main;

use strict;
use warnings;

use File::Temp    qw(tempdir);
use JSON::MaybeXS qw(decode_json);
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Command::HypnotoadBenchmark;

our $VERSION = '0.001';

my $command = GPForum::Command::HypnotoadBenchmark->new;

my $json_output = q{};
open my $json_stdout, '>', \$json_output
  or die 'failed to capture reverse proxy benchmark JSON output';
{
    local *STDOUT = $json_stdout;
    is(
        $command->run(
            '--dry-run',    '--reverse-proxy',
            '--proxy',      'nginx',
            '--json',       '--workers',
            '4',            '--iterations',
            '1',            '--warmup',
            '0',            '--route',
            '/health/live', '--frontend-port',
            '6011',         '--no-direct-compare',
        ),
        0,
        'reverse proxy dry-run JSON command succeeds'
    );
}
close $json_stdout
  or die 'failed to close reverse proxy benchmark JSON capture';

my $json_report = decode_json($json_output);
is( $json_report->{mode},
    'hypnotoad-reverse-proxy', 'dry-run reports reverse proxy mode' );
is( $json_report->{status}, 'dry-run', 'dry-run avoids live processes' );
is( $json_report->{runtime}{reverse_proxy}{requested},
    'nginx', 'dry-run reports requested proxy' );
is( $json_report->{runtime}{frontend}{port},
    6011, 'dry-run reports requested frontend port' );
is( $json_report->{runtime}{backend_hypnotoad}{workers_requested},
    4, 'dry-run reports backend worker count' );
is( $json_report->{comparison}{direct_enabled},
    0, 'dry-run honors disabled direct comparison' );
is( $json_report->{routes}[0],
    '/health/live', 'dry-run reports selected route' );

my $text_report = $command->format_report(
    {
        mode       => 'hypnotoad-reverse-proxy',
        status     => 'ok',
        iterations => 1,
        warmup     => 0,
        dataset    => { profile => 'small' },
        runtime    => {
            workers_requested => 2,
            master_pid        => 123,
            worker_pids       => [124],
            frontend          => {
                base_url => 'http://127.0.0.1:8001',
                port     => 8001,
            },
            backend_hypnotoad => {
                base_url          => 'http://127.0.0.1:9001',
                port              => 9001,
                workers_requested => 2,
            },
            reverse_proxy => {
                name    => 'nginx',
                version => 'nginx version: nginx/1.25.0',
            },
        },
        comparison => { direct_enabled => 1 },
        routes     => [
            {
                route       => '/search?q=performance',
                status      => 'ok',
                requests    => 1,
                req_per_sec => '100.000',
                p50_ms      => '1.000',
                p95_ms      => '1.000',
                p99_ms      => '1.000',
                error_rate  => '0.000',
                db_queries  => {
                    observed              => 1,
                    max_queries           => 2,
                    avg_queries           => '2.000',
                    max_transactions      => 1,
                    max_duplicate_queries => 0,
                    budget_status         => 'ok',
                },
                query_budget => 'search',
                comparison   => { status => 'ok' },
                status_codes => { 200    => 1 },
            },
        ],
    },
    'text',
);

like(
    $text_report,
    qr/mode=hypnotoad-reverse-proxy/msx,
    'text report names reverse proxy mode'
);
like( $text_report, qr/proxy=nginx/msx, 'text report names proxy' );
like(
    $text_report,
    qr/proxy_version=nginx_version:_nginx\/1[.]25[.]0/msx,
    'text report includes proxy version'
);
like( $text_report, qr/frontend_port=8001/msx,
    'text report includes frontend port' );
like(
    $text_report,
    qr/backend_hypnotoad=http:\/\/127[.]0[.]0[.]1:9001/msx,
    'text report includes backend Hypnotoad URL'
);
like(
    $text_report,
    qr/direct_comparison=enabled/msx,
    'text report includes direct comparison state'
);
like( $text_report, qr/query_budget=search/msx,
    'text report includes observed query budget endpoint' );
like(
    $text_report,
    qr/db_queries=max=2,avg=2[.]000/msx,
    'text report includes observed DB query budget counters'
);

{
    my $empty_path = tempdir( CLEANUP => 1 );
    local $ENV{PATH} = $empty_path;

    throws_ok(
        sub { GPForum::Command::HypnotoadBenchmark::_resolve_proxy('auto'); },
qr/reverse [ ] proxy [ ] binary [ ] not [ ] found; [ ] searched [ ] nginx [ ] and [ ] haproxy/msx,
        'auto proxy resolution fails explicitly when no binary is present'
    );
    throws_ok(
        sub { GPForum::Command::HypnotoadBenchmark::_resolve_proxy('nginx'); },
        qr/reverse [ ] proxy [ ] binary [ ] not [ ] found: [ ] nginx/msx,
        'explicit proxy resolution names missing binary'
    );
}

my $nginx_config = GPForum::Command::HypnotoadBenchmark::_reverse_proxy_config(
    {
        kind          => 'nginx',
        pid_file      => '/tmp/gpforum-nginx.pid',
        log_file      => '/tmp/gpforum-nginx.log',
        frontend_port => 7001,
        backend_port  => 7002,
    }
);
like(
    $nginx_config,
    qr/daemon [ ] off;/msx,
    'nginx config keeps the proxy in foreground'
);
like(
    $nginx_config,
    qr/listen [ ] 127[.]0[.]0[.]1:7001;/msx,
    'nginx config binds frontend port'
);
like(
    $nginx_config,
    qr/proxy_pass [ ] http:\/\/127[.]0[.]0[.]1:7002;/msx,
    'nginx config points at backend Hypnotoad'
);
like(
    $nginx_config,
    qr/X-Forwarded-Proto [ ] http;/msx,
    'nginx config forwards proxy headers'
);

my $haproxy_config =
  GPForum::Command::HypnotoadBenchmark::_reverse_proxy_config(
    {
        kind          => 'haproxy',
        pid_file      => '/tmp/gpforum-haproxy.pid',
        log_file      => '/tmp/gpforum-haproxy.log',
        frontend_port => 7101,
        backend_port  => 7102,
    }
  );
like(
    $haproxy_config,
    qr/bind [ ] 127[.]0[.]0[.]1:7101/msx,
    'HAProxy config binds frontend port'
);
like(
    $haproxy_config,
    qr/server [ ] hypnotoad [ ] 127[.]0[.]0[.]1:7102/msx,
    'HAProxy config points at backend Hypnotoad'
);
like(
    $haproxy_config,
    qr/X-Forwarded-Proto [ ] http/msx,
    'HAProxy config forwards proxy headers'
);

is_deeply(
    [
        GPForum::Command::HypnotoadBenchmark::_reverse_proxy_command(
            'haproxy', '/usr/sbin/haproxy', '/tmp/haproxy.cfg'
        )
    ],
    [ '/usr/sbin/haproxy', '-f', '/tmp/haproxy.cfg', '-db' ],
    'HAProxy command stays in foreground for cleanup'
);

my $backend_stops = 0;
my $proxy_stops   = 0;
{
    no warnings 'redefine';
    local *GPForum::Command::HypnotoadBenchmark::_assert_database_available =
      sub { return; };
    local *GPForum::Command::HypnotoadBenchmark::_start_hypnotoad =
      sub { return _fake_backend_runtime(); };
    local *GPForum::Command::HypnotoadBenchmark::_wait_until_ready =
      sub { return 1; };
    local *GPForum::Command::HypnotoadBenchmark::_resolve_proxy =
      sub { return _fake_resolved_proxy(); };
    local *GPForum::Command::HypnotoadBenchmark::_runtime_report =
      sub { return _fake_direct_report(); };
    local *GPForum::Command::HypnotoadBenchmark::_start_reverse_proxy =
      sub { die "proxy start failed\n"; };
    local *GPForum::Command::HypnotoadBenchmark::_stop_hypnotoad =
      sub { $backend_stops++; };
    local *GPForum::Command::HypnotoadBenchmark::_stop_reverse_proxy = sub {
        my ($runtime) = @_;
        $proxy_stops++ if $runtime;
        return;
    };

    throws_ok(
        sub { $command->benchmark_report( _live_proxy_options() ); },
        qr/proxy [ ] start [ ] failed/msx,
        'benchmark surfaces proxy start failure'
    );
}
is( $backend_stops, 1,
    'backend Hypnotoad is stopped after proxy start failure' );
is( $proxy_stops, 0, 'proxy stop is skipped when proxy did not start' );

$backend_stops = 0;
$proxy_stops   = 0;
{
    no warnings 'redefine';
    local *GPForum::Command::HypnotoadBenchmark::_assert_database_available =
      sub { return; };
    local *GPForum::Command::HypnotoadBenchmark::_start_hypnotoad =
      sub { return _fake_backend_runtime(); };
    local *GPForum::Command::HypnotoadBenchmark::_wait_until_ready =
      sub { return 1; };
    local *GPForum::Command::HypnotoadBenchmark::_resolve_proxy =
      sub { return _fake_resolved_proxy(); };
    local *GPForum::Command::HypnotoadBenchmark::_start_reverse_proxy =
      sub { return _fake_proxy_runtime(); };
    local *GPForum::Command::HypnotoadBenchmark::_route_report =
      sub { die "proxy route failed\n"; };
    local *GPForum::Command::HypnotoadBenchmark::_stop_hypnotoad =
      sub { $backend_stops++; };
    local *GPForum::Command::HypnotoadBenchmark::_stop_reverse_proxy = sub {
        my ($runtime) = @_;
        $proxy_stops++ if $runtime;
        return;
    };

    throws_ok(
        sub {
            $command->benchmark_report(
                _live_proxy_options( compare_direct => 0 ) );
        },
        qr/proxy [ ] route [ ] failed/msx,
        'benchmark surfaces proxied route failure'
    );
}
is( $proxy_stops,   1, 'proxy is stopped after route failure' );
is( $backend_stops, 1, 'backend Hypnotoad is stopped after route failure' );

done_testing;

sub _live_proxy_options {
    my (%overrides) = @_;

    return {
        accepts              => 100,
        backlog              => 128,
        check                => 0,
        clients              => 100,
        compare_direct       => 1,
        compare_in_process   => 0,
        dry_run              => 0,
        format               => 'text',
        frontend_port        => undef,
        graceful             => 10,
        inactivity           => 30,
        iterations           => 1,
        keep_alive           => 5,
        port                 => undef,
        profile              => 'small',
        proxy_kind           => 'auto',
        regression_tolerance => 5,
        reverse_proxy        => 1,
        routes               => ['/health/live'],
        seed                 => 0,
        warmup               => 0,
        workers              => 2,
        %overrides,
    };
}

sub _fake_backend_runtime {
    return {
        base_url    => 'http://127.0.0.1:9001',
        environment => {},
        log_file    => '/tmp/gpforum-hypnotoad.log',
        pid_file    => '/tmp/gpforum-hypnotoad.pid',
        port        => 9001,
        process_pid => 9000,
    };
}

sub _fake_proxy_runtime {
    return {
        base_url    => 'http://127.0.0.1:8001',
        kind        => 'nginx',
        log_file    => '/tmp/gpforum-nginx.log',
        pid_file    => '/tmp/gpforum-nginx.pid',
        port        => 8001,
        process_pid => 8000,
    };
}

sub _fake_resolved_proxy {
    return {
        binary  => '/usr/sbin/nginx',
        kind    => 'nginx',
        version => 'nginx/fixture',
    };
}

sub _fake_direct_report {
    return {
        mode       => 'hypnotoad',
        status     => 'ok',
        iterations => 1,
        warmup     => 0,
        dataset    => { profile => 'small' },
        routes     => [],
        runtime    => {},
        comparison => {},
    };
}
