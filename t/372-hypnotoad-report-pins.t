# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use POSIX      qw(WNOHANG);
use Test::Exception;
use Test::More;
use Time::HiRes qw(sleep time);

use lib 'lib';
use lib 't/lib';

use GPForum::Benchmark::HypnotoadText qw(text_report);
use GPForum::Benchmark::Measure       qw(error_rate);
use GPForum::Benchmark::Process       qw(
  command_output free_port read_pid_file worker_pids
);
use GPForum::Command::HypnotoadBenchmark;
use GPForum::Test::RecordingUserAgent;
use GPForum::Test::ReplacedSubs qw(with_replaced_subs);

our $VERSION = '0.001';

# What the hypnotoad benchmark does around the numbers t/57 and t/60 check:
# the requests a route is measured with, the comparison it says it made, the
# text an operator reads, and the processes and proxy it runs. Each moved
# into Benchmark::Measure, Process, ReverseProxy or HypnotoadText; none was
# pinned, and a lost one would only show as a benchmark that measures, or
# says, something else than it did.

const my $WARMUP          => 2;
const my $ITERATIONS      => 3;
const my $OK              => 200;
const my $NOT_FOUND       => 404;
const my $SERVER_ERROR    => 500;
const my $EXECUTABLE_MODE => oct 755;
const my $READY_TIMEOUT   => 0.3;
const my $READY_LIMIT     => 5;
const my $SETTLE_SECONDS  => 0.05;

# Instrumented children can need eight seconds to reach their ready marker.
# Allow fixtures thirty seconds; keep the production timeout pinned separately
# by _test_wait_until_ready.
const my $SETTLE_ATTEMPTS => 600;
const my $NO_CHILD        => -1;
const my $FRONTEND_PORT   => 18_081;
const my $BACKEND_PORT    => 18_080;
const my $PID             => 4_242;
const my $PROCESS_COLUMNS => 80;

my $directory = tempdir( CLEANUP => 1 );

_test_error_rate();
_test_route_requests();
_test_comparison_flags();
_test_text_report();
_test_wait_until_ready();
_test_terminate_after_kill();
_test_command_output();
_test_read_pid_file();
_test_worker_pids();
_test_resolve_proxy();
_test_start_proxy();

done_testing();

sub _test_error_rate {
    is( error_rate( { $OK => 3, $SERVER_ERROR => 1 } ),
        '0.250', 'the error rate is the share of all responses that failed' );
    is( error_rate( {} ), '0.000', 'and none without responses' );

    return;
}

# Each route is warmed, then sampled; every request reads the status and the
# query counts the response's headers report, and a count that is not a
# whole number reads as none.
sub _test_route_requests {
    my $ua = GPForum::Test::RecordingUserAgent->new(
        code    => $NOT_FOUND,
        headers => {
            'X-GPForum-DB-Queries'      => '2.5',
            'X-GPForum-DB-Transactions' => '1',
        },
    );
    my $summary = _private('_route_report')->(
        { base_url => 'http://127.0.0.1:1', ua => $ua },
        '/health/live',
        {
            warmup               => $WARMUP,
            iterations           => $ITERATIONS,
            regression_tolerance => 5,
        },
        undef,
    );

    is_deeply(
        $ua->urls,
        [ ('http://127.0.0.1:1/health/live') x ( $WARMUP + $ITERATIONS ) ],
        'a route is requested warmup and iterations times'
    );
    is_deeply(
        $summary->{status_codes},
        { $NOT_FOUND => $ITERATIONS },
        'only the sampled requests are counted, by the status they answered'
    );
    is( $summary->{error_rate}, '1.000', 'and their error rate' );
    is( $summary->{db_queries}{max_queries},
        0, 'a query count that is not a whole number reads as none' );
    is( $summary->{db_queries}{max_transactions}, 1, 'a whole one is read' );

    return;
}

sub _test_comparison_flags {
    my $options  = { routes => [q{/}], regression_tolerance => 5 };
    my $baseline = { routes => [ { route => q{/} } ] };
    my %measured = (
        _route_report     => sub { return { route => $_[1], status => 'ok' } },
        _runtime_metadata => sub { return {} },
        _reverse_proxy_runtime_metadata => sub { return {} },
    );

    for my $case (
        [ '_runtime_report',       'in_process' ],
        [ '_reverse_proxy_report', 'direct' ],
      )
    {
        my ( $name, $kind ) = @{$case};
        my $report = sub ($compared) {
            return with_replaced_subs(
                q{GPForum::Command::HypnotoadBenchmark},
                \%measured,
                sub {
                    _private($name)->(
                        ( $name eq '_runtime_report' ? () : ( {} ) ),
                        {}, $options, $compared
                    );
                }
            )->{comparison};
        };
        is_deeply(
            $report->(undef),
            {
                "${kind}_enabled"    => 0,
                regression_tolerance => 5,
                $kind                => undef,
            },
            "$name says when it compared with no $kind run"
        );
        is_deeply(
            $report->($baseline),
            {
                "${kind}_enabled"    => 1,
                regression_tolerance => 5,
                $kind                => $baseline,
            },
            "and carries the $kind run it compared with"
        );
    }

    return;
}

sub _test_text_report {
    my $route = {
        route        => q{/},
        status       => 'ok',
        requests     => 1,
        req_per_sec  => '1.000',
        p50_ms       => '1.000',
        p95_ms       => '1.000',
        p99_ms       => '1.000',
        error_rate   => '0.000',
        query_budget => undef,
        db_queries   => undef,
        comparison   => undef,
        status_codes => { $OK => 1 },
    };
    my $text = text_report(
        {
            mode       => 'hypnotoad-reverse-proxy',
            status     => 'ok',
            iterations => 1,
            warmup     => 0,
            dataset    => { profile        => 'small' },
            comparison => { direct_enabled => 0 },
            runtime    => {
                workers_requested => 2,
                master_pid        => 0,
                worker_pids       => [],
                reverse_proxy     =>
                  { name => 'nginx', version => "nginx version:\n 1.2" },
                frontend    => { port   => 1 },
                os_evidence => { status => q{} },
            },
            routes => [$route],
        }
    );

    is(
        $text,
        join( q{ },
            'mode=hypnotoad-reverse-proxy status=ok iterations=1 warmup=0',
            'dataset_profile=small workers=2 master_pid=unknown',
            'worker_pids=none proxy=nginx proxy_version=nginx_version:_1.2',
            'frontend_port=1 frontend_url=unknown backend_hypnotoad=unknown',
            "direct_comparison=off\n" )
          . join( q{ },
            'os_evidence_status=unknown declared_event_backend=unknown',
            'actual_reactor=unknown reuseport_configured=0',
            'reuseport_verified=0 sendfile_materialized=0',
            "postgresql_settings=unavailable temp_mount=unknown \n" )
          . join( q{ },
            'route=/ status=ok requests=1 req_per_sec=1.000 p50_ms=1.000',
            'p95_ms=1.000 p99_ms=1.000 error_rate=0.000 query_budget=none',
            'db_queries=not-observed comparison=not-checked statuses=200:1',
            "\n" ),
        'what a report does not know reads as unknown, none or not-checked'
    );

    return;
}

sub _test_wait_until_ready {
    my $log     = "$directory/never.log";
    my $started = time;
    throws_ok {
        _private('_wait_until_ready')->(
            {
                base_url    => 'http://127.0.0.1:' . free_port(),
                environment => { GPFORUM_STARTUP_TIMEOUT => $READY_TIMEOUT },
                log_file    => $log,
                ua          => Mojo::UserAgent->new( request_timeout => 1 ),
            },
            'the server'
        );
    }
    qr{server [ ] did [ ] not [ ] become [ ] ready; [ ] see [ ] \Q$log\E}msx,
      'a server that never answers is given up on';
    cmp_ok( time - $started,
        q{<}, $READY_LIMIT, 'after the startup timeout its environment sets' );

    return;
}

# A group that ignores TERM is killed, and reaped.
sub _test_terminate_after_kill {
    my $ignoring = "$directory/ignoring-term";
    my $pid      = _private('_spawn')->(
        {
            name     => 'stubborn',
            log_file => "$directory/stubborn.log",
            session  => 1,
        },
        $EXECUTABLE_NAME,
        '-e',
        q{$SIG{TERM} = q{IGNORE}; open my $f, q{>}, $ARGV[0] or exit 1;}
          . q{ close $f or exit 1; sleep 60},
        $ignoring,
    );

    # TERM sent before the child ignores it would end it the polite way.
    _wait_until( sub { return -e $ignoring }, $pid );

    _private('_terminate')->( { process_pid => $pid } );

    is( waitpid( $pid, WNOHANG ),
        $NO_CHILD, 'a group that ignores TERM is killed and reaped' );

    return;
}

sub _test_command_output {
    is(
        command_output(
            $EXECUTABLE_NAME,
            '-e',
            'print {*STDOUT} qq{nginx\n}; print {*STDERR} qq{ version:  1.2\n}'
        ),
        'nginx version: 1.2',
        'a command\'s output is both its streams, its whitespace folded'
    );
    is( command_output( $EXECUTABLE_NAME, '-e', '1' ),
        'unknown', 'and unknown when it prints nothing' );

    return;
}

sub _test_read_pid_file {
    my $file = "$directory/server.pid";
    path($file)->spew(" $PID \n");
    is( read_pid_file($file), $PID, 'a pid file holds its pid' );
    path($file)->spew("$PID abc\n");
    is( read_pid_file($file), undef, 'and nothing when it holds more' );
    is( read_pid_file("$directory/absent.pid"),
        undef, 'or when there is none' );

    return;
}

# A master's workers are its own children that run hypnotoad or GPForum: not
# another process, not a grandchild. The marker comes after the code, beyond a
# narrow terminal's width, so ps must report the entire command line. The
# whole line stays under 256 bytes: FreeBSD keeps no more of a process's
# arguments (kern.ps_arg_cache_limit) and ps then shows the bare name.
sub _test_worker_pids {
    local $ENV{COLUMNS} = $PROCESS_COLUMNS;
    my $worker = _spawn_sleeper( 'gpforum-benchmark-worker',
            'my $p = fork; if ( !$p ) { exec $^X, q{-e}, q{sleep 60},'
          . ' q{gpforum-benchmark-grandchild} } sleep 60' );
    my $other = _spawn_sleeper( 'benchmark-sidecar', 'sleep 60' );
    _wait_until( sub { return _ps_lists('gpforum-benchmark-grandchild') },
        $worker, $other );

    is_deeply( worker_pids($PROCESS_ID),
        [$worker], 'a master\'s workers are its GPForum children' );

    kill 'KILL', -$worker, -$other;
    for my $pid ( $worker, $other ) {
        waitpid $pid, 0;
    }

    return;
}

sub _test_resolve_proxy {
    my $bin = "$directory/bin";
    mkdir $bin or croak "cannot make $bin";
    path("$bin/nginx")->spew("#!/bin/sh\nexit 0\n")->chmod($EXECUTABLE_MODE);
    path("$bin/haproxy")
      ->spew("#!/bin/sh\necho 'HAProxy  version 3' >&2\n")
      ->chmod($EXECUTABLE_MODE);
    local $ENV{PATH} = $bin;

    is_deeply(
        _private('_resolve_proxy')->('auto'),
        { kind => 'nginx', binary => "$bin/nginx", version => 'nginx' },
        'a proxy that reports no version is named by its kind'
    );
    is_deeply(
        _private('_resolve_proxy')->('haproxy'),
        {
            kind    => 'haproxy',
            binary  => "$bin/haproxy",
            version => 'HAProxy version 3',
        },
        'one that does by the version it reports'
    );

    return;
}

sub _test_start_proxy {
    my $runtime = _private('_start_reverse_proxy')->(
        { port => $BACKEND_PORT, base_url => 'http://127.0.0.1:18080' },
        { frontend_port => $FRONTEND_PORT },
        { kind => 'haproxy', binary => '/usr/bin/true', version => 'v' },
    );
    _private('_terminate')->($runtime);

    is(
        $runtime->{base_url},
        "http://127.0.0.1:$FRONTEND_PORT",
        'the proxy is reached on the frontend port of the loopback address'
    );
    is( $runtime->{port}, $FRONTEND_PORT, 'on the port asked for' );
    is_deeply(
        $runtime->{command},
        [ '/usr/bin/true', '-f', $runtime->{config_file}, '-db' ],
        'running the configuration it was given'
    );
    like(
        path( $runtime->{config_file} )->slurp,
        qr/^ \s+ server [ ] hypnotoad [ ] 127[.]0[.]0[.]1:$BACKEND_PORT $/msx,
        'which forwards to the backend hypnotoad'
    );

    return;
}

sub _spawn_sleeper ( $name, $code ) {
    my $pid = fork // croak 'cannot fork';
    if ( !$pid ) {
        POSIX::setsid();
        exec $EXECUTABLE_NAME, '-e', $code, $name or POSIX::_exit(1);
    }

    return $pid;
}

sub _ps_lists ($name) {
    open my $ps, q{-|}, 'ps', '-axww', '-o', 'command='
      or croak 'cannot run ps';
    my $found = grep { /\Q$name\E/msx } <$ps>;
    close $ps or croak 'ps failed';

    return $found;
}

sub _wait_until ( $condition, @children ) {
    for ( 1 .. $SETTLE_ATTEMPTS ) {
        return if $condition->();
        sleep $SETTLE_SECONDS;
    }
    @children = grep { defined $_ && $_ > 0 } @children;
    kill 'KILL', map { -$_ } @children;
    kill 'KILL', @children;
    for my $pid (@children) {
        waitpid $pid, 0;
    }
    croak 'the condition never held';
}

sub _private ($name) {
    return GPForum::Command::HypnotoadBenchmark->can($name) // croak "no $name";
}

1;
