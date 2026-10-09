# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';

use GPForum::Benchmark::Measure qw(
  average db_query_text endpoint_name error_count nonzero overall_status
  percentile query_summary regressions rounded route_summary sample_route
  statuses_text threshold_for threshold_status
);

our $VERSION = '0.001';

# The in-process and the hypnotoad benchmarks judge a route by these rules
# alone: a percentile one rank off, or a threshold a millisecond looser,
# passes a route that should fail. Each rule is pinned on its own, so a change
# to one shows here rather than as a benchmark that quietly stops failing.

const my @ONE_TO_TEN => ( 1 .. 10 );

# [ sorted values, percentile, expected, label ]
const my @PERCENTILES => (
    [ \@ONE_TO_TEN, 50,  5,  'p50 of 1..10 is the fifth value' ],
    [ \@ONE_TO_TEN, 95,  9,  'p95 of 1..10 is the ninth: the rank below' ],
    [ \@ONE_TO_TEN, 99,  9,  'p99 of 1..10 is still the ninth' ],
    [ \@ONE_TO_TEN, 100, 10, 'p100 is the largest' ],
    [ [7],          95,  7,  'one value is every percentile' ],
    [ [],           95,  0,  'no values measure 0' ],
);

# [ function, arguments, expected, label ]
const my @CASES => (
    [ q{average}, [ 1, 2, 6 ], 3,       'the average is the mean' ],
    [ q{average}, [],          0,       'no values average 0' ],
    [ q{rounded}, [1],         '1.000', 'rounded keeps three decimals' ],
    [ q{rounded}, [2.718_281], '2.718', 'and rounds to them' ],
    [ q{nonzero}, [2],         2,       'a positive elapsed time is kept' ],
    [ q{nonzero}, [ 0], 0.000_001, 'no elapsed time becomes a microsecond' ],
    [ q{nonzero}, [-1], 0.000_001, 'nor does a clock that went backwards' ],
    [
        q{error_count}, [ { 200 => 5, 302 => 2, 399 => 1 } ],
        0,              '2xx and 3xx are not errors'
    ],
    [
        q{error_count}, [ { 200 => 5, 404 => 2, 500 => 3, 199 => 1 } ],
        6,              'everything else is'
    ],
    [
        q{statuses_text},    [ { 500 => 1, 200 => 5, 404 => 2 } ],
        '200:5,404:2,500:1', 'status counts read in status order'
    ],
    [
        q{db_query_text}, [undef], 'not-observed',
        'no summary was not observed'
    ],
    [
        q{db_query_text}, [ { observed => 0 } ],
        'not-observed',   'nor was an unobserved one'
    ],
    [
        q{db_query_text},
        [
            {
                observed              => 1,
                max_queries           => 4,
                avg_queries           => '3.500',
                max_transactions      => 1,
                max_duplicate_queries => 0,
                budget_status         => 'ok',
            }
        ],
        'max=4,avg=3.500,transactions=1,duplicates=0,budget=ok',
        'an observed summary is one report field'
    ],
    [
        q{overall_status}, [ [ { status => 'ok' }, { status => 'ok' } ] ],
        'ok',              'every route ok is ok'
    ],
    [
        q{overall_status}, [ [ { status => 'ok' }, { status => 'fail' } ] ],
        'fail',            'one failing route fails the run'
    ],
    [ q{overall_status}, [ [] ], 'ok', 'no routes fail nothing' ],
);

const my %ENDPOINT_FOR => (
    q{/}                         => 'home',
    q{/categories}               => 'categories',
    q{/c/category-1}             => 'category_threads',
    q{/t/thread-1}               => 'thread_view',
    q{/search?q=perl}            => 'search',
    q{/search/autocomplete?q=pe} => 'search_autocomplete',
);

const my %DEFAULT_LIMITS => (
    p95_ms          => 1_000,
    p99_ms          => 2_000,
    min_req_per_sec => 1,
);
const my %THRESHOLD_FOR => (
    q{/}           => { p95_ms => 750, p99_ms => 1_500, min_req_per_sec => 1 },
    q{/categories} => { p95_ms => 500, p99_ms => 1_000, min_req_per_sec => 1 },
    q{/c/x}          => {%DEFAULT_LIMITS},
    q{/t/x}          => {%DEFAULT_LIMITS},
    q{/search}       => {%DEFAULT_LIMITS},
    q{/health}       => {%DEFAULT_LIMITS},
    q{/search/auto/} => {%DEFAULT_LIMITS},
);

# [ p95, p99, requests per second, expected, label ] against LIMITS.
const my %LIMITS => ( p95_ms => 100, p99_ms => 200, min_req_per_sec => 5 );
const my @THRESHOLD_STATUSES => (
    [ 100,     200,     5,     'ok',   'at the limits is ok' ],
    [ 100.001, 200,     5,     'fail', 'a slower p95 fails' ],
    [ 100,     200.001, 5,     'fail', 'a slower p99 fails' ],
    [ 100,     200,     4.999, 'fail', 'fewer requests per second fail' ],
);

for my $case (@PERCENTILES) {
    my ( $sorted, $rank, $expected, $label ) = @{$case};
    is( percentile( $sorted, $rank ), $expected, $label );
}

for my $case (@CASES) {
    my ( $function, $arguments, $expected, $label ) = @{$case};
    is( main->can($function)->( @{$arguments} ), $expected, $label );
}

for my $route ( sort keys %ENDPOINT_FOR ) {
    is( endpoint_name($route), $ENDPOINT_FOR{$route},
        "$route measures $ENDPOINT_FOR{$route}" );
}
for my $route (qw(/health /health/live /health/ready /metrics /elsewhere)) {
    is( endpoint_name($route), undef, "$route measures no page" );
}

for my $route ( sort keys %THRESHOLD_FOR ) {
    is_deeply( threshold_for($route), $THRESHOLD_FOR{$route},
        "$route has its endpoint's limits" );
}
my $copy = threshold_for(q{/});
$copy->{p95_ms} = 1;
is_deeply( threshold_for(q{/}), $THRESHOLD_FOR{q{/}},
    'each threshold is a fresh copy' );

for my $case (@THRESHOLD_STATUSES) {
    my ( $p95, $p99, $rps, $expected, $label ) = @{$case};
    is( threshold_status( $p95, $p99, $rps, {%LIMITS} ), $expected, $label );
}

# What a route's queries can do to its status, on a route that meets its
# latency limits with no error: [ query summary, expected, label ].
const my @QUERY_VERDICTS => (
    [
        { observed => 0, budget_status => 'not-observed' },
        'ok',
        'unobserved queries judge nothing'
    ],
    [ _queries( 'fail', 0 ), 'fail', 'a broken budget fails' ],
    [ _queries( 'ok',   1 ), 'fail', 'a duplicate within a budget fails' ],
    [ _queries( 'none', 1 ), 'ok',   'a duplicate with no budget is allowed' ],
    [ _queries( 'ok',   0 ), 'ok',   'a kept budget passes' ],
);

# Samples: two passing requests in a second, three in half a second (one
# rank apart at every percentile), and a request that was not found.
const my %TWO_IN_A_SECOND =>
  ( latencies => [ 1, 2 ], statuses => { 200 => 2 }, elapsed => 1 );
const my %THREE_IN_HALF =>
  ( latencies => [ 3, 1, 2 ], statuses => { 200 => 3 }, elapsed => 0.5 );
const my @THREE_MEASURED => ( 3, '6.000', '2.000', '2.000', '3.000' );
const my %NOT_FOUND =>
  ( latencies => [1], statuses => { 404 => 1 }, elapsed => 1 );

const my @OBSERVED => (
    { queries => 2, transactions      => 1 },
    { queries => 5, duplicate_queries => 2 },
);
const my %OBSERVED_SUMMARY => (
    observed              => 1,
    samples               => 2,
    max_queries           => 5,
    avg_queries           => '3.500',
    max_transactions      => 1,
    max_duplicate_queries => 2,
    budget_status         => undef,
);

# What three requests answered, and the samples they make.
const my @ANSWERS => (
    { status => 200, elapsed_ms => 4, db_query_stats => { queries => 1 } },
    { status => 500, elapsed_ms => 6, db_query_stats => undef },
    { status => 200, elapsed_ms => 5, db_query_stats => { queries => 2 } },
);
const my @SAMPLED => (
    [ 4, 6, 5 ],
    { 200 => 2, 500 => 1 },
    [ { queries => 1 }, { queries => 2 } ],
);

# A baseline, a 10% tolerance, a route just within it, one just beyond.
const my %BASELINE  => ( p95_ms => 10, p99_ms => 20, req_per_sec => 100 );
const my $TOLERANCE => 0.1;
const my %WITHIN    => ( p95_ms => 11,   p99_ms => 22,   req_per_sec => 90 );
const my %BEYOND    => ( p95_ms => 11.1, p99_ms => 22.1, req_per_sec => 89 );
const my @BEYOND_ALLOWED => (
    [ 'p95_ms',      '11.000' ],
    [ 'p99_ms',      '22.000' ],
    [ 'req_per_sec', '90.000' ],
);

for my $case (@QUERY_VERDICTS) {
    my ( $queries, $expected, $label ) = @{$case};
    is( route_summary( q{/}, {%TWO_IN_A_SECOND}, $queries )->{status},
        $expected, $label );
}

my $summary = route_summary( q{/}, {%THREE_IN_HALF}, _queries( 'ok', 0 ) );
is_deeply(
    [ @{$summary}{qw(requests req_per_sec p50_ms p99_ms max_ms)} ],
    [@THREE_MEASURED],
    'a route summary counts, divides and ranks its sorted latencies'
);
is( route_summary( q{/}, {%NOT_FOUND}, _queries( 'ok', 0 ) )->{status},
    'fail', 'an error response fails the route' );

is_deeply( query_summary( [ map { +{ %{$_} } } @OBSERVED ] ),
    {%OBSERVED_SUMMARY},
    'a query summary takes the maxima and the mean, and leaves the verdict' );

my @answers = @ANSWERS;
my $samples = sample_route( scalar @answers, sub { return shift @answers; } );
is_deeply( [ @{$samples}{qw(latencies statuses observations)} ],
    [@SAMPLED],
    'samples keep each latency and status, and only reported queries' );

is_deeply( [ regressions( {%WITHIN}, {%BASELINE}, $TOLERANCE ) ],
    [], 'a route within the tolerance has no regression' );
is_deeply(
    [
        map { [ @{$_}{qw(metric allowed)} ] }
          regressions( {%BEYOND}, {%BASELINE}, $TOLERANCE )
    ],
    [@BEYOND_ALLOWED],
    'a route beyond it regresses on each metric, slower or fewer'
);
is_deeply(
    [
        regressions(
            { %WITHIN,   req_per_sec => 0 },
            { %BASELINE, req_per_sec => 0 },
            $TOLERANCE
        )
    ],
    [],
    'a baseline that served nothing sets no throughput floor'
);

done_testing();

sub _queries ( $budget_status, $duplicates ) {
    return {
        observed              => 1,
        budget_status         => $budget_status,
        max_duplicate_queries => $duplicates,
    };
}

1;
