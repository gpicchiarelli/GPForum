# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Benchmark;
use GPForum::Command::HypnotoadBenchmark;
use GPForum::Command::QueryPlanEvidence;
use GPForum::Test::QueryPlanEvidenceDbh;
use GPForum::Test::ReplacedSubs qw(with_replaced_subs);

our $VERSION = '0.001';

# The paths the benchmark commands folded into their callers (the warm-up, the
# request sample's query count, the text line, the hypnotoad baseline lookup,
# the query plan help, database error, DSN redaction and deep-page cache),
# pinned as they read before the fold.

const my $WARMUP           => 3;
const my $ITERATIONS       => 4;
const my $QUERIES          => 2;
const my $TICK_SECONDS     => 0.25;
const my $TOLERANCE        => 0.25;
const my $EXIT_USAGE       => 2;
const my $PID              => 4242;
const my $HTTP_OK          => 200;
const my $CATEGORIES_LIMIT => 3;

my $benchmark = GPForum::Command::Benchmark->new(
    app_class => 'GPForum::Test::QueryCountingApp' );

_test_warmup_requests();
_test_query_count_of_this_request();
_test_request_elapsed_time();
_test_route_text_line();
_test_hypnotoad_baseline_routes();
_test_query_plan_help();
_test_query_plan_database_error();
_test_query_plan_redacted_dsn();
_test_query_plan_deep_pages_per_report();

done_testing();

sub _test_warmup_requests {
    my $sample   = _private( 'GPForum::Command::Benchmark', '_request_sample' );
    my $requests = 0;
    with_replaced_subs(
        'GPForum::Command::Benchmark',
        {
            _request_sample => sub (@arguments) {
                $requests++;
                return $sample->(@arguments);
            },
        },
        sub {
            $benchmark->benchmark_report( '--configured', '--iterations',
                $ITERATIONS, '--warmup', $WARMUP, '--route', '/attached', );
        }
    );
    is(
        $requests,
        $WARMUP + $ITERATIONS,
        'each route is requested warmup plus iterations times'
    );

    return;
}

sub _test_query_count_of_this_request {
    my $report = $benchmark->benchmark_report(
        '--configured', '--iterations', $ITERATIONS, '--warmup',
        0,              '--route',      '/attached', '--route',
        '/detached',
    );
    my ( $attached, $detached ) = @{ $report->{routes} };

    is( $attached->{db_queries}{observed},
        1, 'an attached counter reports the request\'s queries' );
    is( $attached->{db_queries}{max_queries},
        $QUERIES, 'with the queries the request ran' );
    is( $attached->{db_queries}{samples},
        $ITERATIONS, 'one observation per measured request' );
    is_deeply(
        $detached->{db_queries},
        { observed => 0, budget_status => 'not-observed' },
        'a counter not attached to the schema is not this request\'s count'
    );

    return;
}

sub _test_request_elapsed_time {
    my $tick   = 0;
    my $report = with_replaced_subs(
        'GPForum::Command::Benchmark',
        { time => sub { return $TICK_SECONDS * $tick++; } },
        sub {
            return $benchmark->benchmark_report( '--configured',
                '--iterations', $ITERATIONS, '--warmup', 0, '--route',
                '/attached', );
        }
    );
    my $route = $report->{routes}[0];

    is( $route->{p50_ms}, '250.000',
        'a request\'s latency is its elapsed seconds in milliseconds' );
    is( $route->{max_ms}, '250.000', 'for every request' );

    return;
}

sub _test_route_text_line {
    my %route = (
        status       => 'fail',
        requests     => 2,
        req_per_sec  => '10.000',
        p50_ms       => '1.000',
        p95_ms       => '2.000',
        p99_ms       => '3.000',
        max_ms       => '4.000',
        threshold    => { p95_ms   => 50, p99_ms => 75, min_req_per_sec => 5 },
        db_queries   => { observed => 0 },
        status_codes => { $HTTP_OK => 2 },
    );
    my %checked = (
        %route,
        route        => '/categories',
        regression   => { status => 'fail' },
        query_budget => {
            endpoint_name => 'categories',
            max_queries   => $CATEGORIES_LIMIT,
        },
    );
    my %unchecked = (
        %route,
        route        => '/elsewhere',
        regression   => undef,
        query_budget => undef,
    );
    my $text = $benchmark->format_report(
        {
            mode       => 'configured',
            status     => 'fail',
            iterations => 2,
            warmup     => 1,
            dataset    => { profile => 'fixture' },
            process    => {
                pid           => $PID,
                worker_count  => 'configured',
                memory_rss_kb => undef,
            },
            routes => [ \%checked, \%unchecked ],
        },
        'text'
    );

    my $measures =
        'requests=2 req_per_sec=10.000 p50_ms=1.000 p95_ms=2.000'
      . ' p99_ms=3.000 max_ms=4.000'
      . ' threshold=p95_ms<=50,p99_ms<=75,req_per_sec>=5';
    is(
        $text,
        'mode=configured status=fail iterations=2 warmup=1'
          . " dataset_profile=fixture pid=$PID worker_count=configured"
          . " memory_rss_kb=unknown\n"
          . "route=/categories status=fail $measures regression=fail"
          . ' query_budget=categories:3 db_queries=not-observed'
          . " statuses=200:2 \n"
          . "route=/elsewhere status=fail $measures regression=not-checked"
          . ' query_budget=none db_queries=not-observed'
          . " statuses=200:2 \n",
        'each route line reads its thresholds, regression and budget'
    );

    return;
}

sub _test_hypnotoad_baseline_routes {
    my $runtime_report =
      _private( 'GPForum::Command::HypnotoadBenchmark', '_runtime_report' );
    my %options = (
        routes               => [qw(/a /b /c)],
        iterations           => 1,
        warmup               => 0,
        profile              => 'small',
        regression_tolerance => $TOLERANCE,
    );
    my $first = { route => '/a', p95_ms => 1 };
    my $later = { route => '/a', p95_ms => 2 };
    my $other = { route => '/b', p95_ms => 1 };

    my %baseline_of;
    my $measure = sub ($in_process) {
        %baseline_of = ();
        return with_replaced_subs(
            'GPForum::Command::HypnotoadBenchmark',
            {
                _route_report => sub ( $runtime, $route, $opts, $baseline ) {
                    $baseline_of{$route} = $baseline;
                    return { route => $route, status => 'ok' };
                },
                _runtime_metadata => sub { return {}; },
            },
            sub { return $runtime_report->( {}, \%options, $in_process ); }
        );
    };

    my $report = $measure->( { routes => [ $first, $later, $other ] } );
    is( $baseline_of{'/a'}, $first,
        'a route is compared with its first row in the baseline' );
    is( $baseline_of{'/b'}, $other, 'each route with its own row' );
    ok(
        exists $baseline_of{'/c'} && !defined $baseline_of{'/c'},
        'and a route the baseline lacks with nothing'
    );
    is( $report->{comparison}{in_process_enabled},
        1, 'the comparison is enabled with a baseline' );

    $report = $measure->(undef);
    is_deeply(
        \%baseline_of,
        { '/a' => undef, '/b' => undef, '/c' => undef },
        'without a baseline no route is compared'
    );
    is( $report->{comparison}{in_process_enabled},
        0, 'and the comparison is disabled' );

    return;
}

sub _test_query_plan_help {
    my ( $status, $stdout ) = _stdout_of(
        sub { return GPForum::Command::QueryPlanEvidence->new->run('--help') }
    );
    is( $status, 0, 'query plan --help exits 0' );
    is(
        $stdout,
        GPForum::Command::QueryPlanEvidence->usage_text . "\n",
        'and prints the usage and a newline'
    );

    return;
}

sub _test_query_plan_database_error {
    my ( $status, $stderr ) = _stderr_of(
        sub {
            return with_replaced_subs(
                'GPForum::Command::QueryPlanEvidence',
                { evidence_report => sub { die "connection refused\n" } },
                sub {
                    return GPForum::Command::QueryPlanEvidence->new->run(
                        '--endpoint', 'home' );
                }
            );
        }
    );
    is( $status, $EXIT_USAGE, 'a database failure exits 2' );
    is(
        $stderr,
        'script/query-plan-evidence: PostgreSQL query plan evidence failed. '
          . 'Run script/bootstrap-deps --postgres, apply migrations, '
          . 'seed benchmark data, and ensure the database is reachable. '
          . "Error: connection refused\n",
        'and says what to check before the error'
    );

    return;
}

sub _test_query_plan_redacted_dsn {
    local $ENV{GPFORUM_DATABASE_DSN} =
      'dbi:Pg:dbname=gpforum;password=secret;host=127.0.0.1';
    my $report = GPForum::Command::QueryPlanEvidence->new(
        dbh => GPForum::Test::QueryPlanEvidenceDbh->new )
      ->evidence_report(
        { analyze => 0, dry_run => 0, endpoints => ['home'] } );
    is(
        $report->{dsn},
        'dbi:Pg:dbname=gpforum;password=<redacted>;host=127.0.0.1',
        'the report names the database without its password'
    );

    return;
}

sub _test_query_plan_deep_pages_per_report {
    my $command = GPForum::Command::QueryPlanEvidence->new;
    my @counts;
    for ( 1 .. 2 ) {
        my $dbh = GPForum::Test::QueryPlanEvidenceDbh->new;
        $command->dbh($dbh);
        $command->evidence_report(
            { analyze => 0, dry_run => 0, endpoints => ['thread_view_deep'] } );
        push @counts, scalar @{ $dbh->statements };
    }
    is( $counts[1], $counts[0],
        'a second report reads its deep page again instead of the first\'s' );

    return;
}

sub _stdout_of ($code) {
    my $captured = q{};
    open my $capture, q{>}, \$captured or croak q{cannot capture stdout};
    my $status;
    {
        local *STDOUT = $capture;
        $status = $code->();
    }
    close $capture or croak q{cannot close stdout};

    return ( $status, $captured );
}

sub _stderr_of ($code) {
    my $captured = q{};
    open my $capture, q{>}, \$captured or croak q{cannot capture stderr};
    my $status;
    {
        local *STDERR = $capture;
        $status = $code->();
    }
    close $capture or croak q{cannot close stderr};

    return ( $status, $captured );
}

sub _private ( $class, $name ) {
    return $class->can($name) // croak "no $class->$name";
}

1;
