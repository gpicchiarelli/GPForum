# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use Mojo::UserAgent;
use Mojolicious;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Benchmark::PlanRules   qw(analyze_plan relation_size);
use GPForum::Benchmark::SeedDataset qw(seed_id);
use GPForum::Command::Benchmark;
use GPForum::Command::HypnotoadBenchmark;
use GPForum::Command::PerformanceSeed;
use GPForum::Command::QueryPlanEvidence;
use GPForum::Test::BindRecordingDbh;

our $VERSION = '0.001';

# What the benchmark commands do with what Benchmark::Measure gives them, and
# the rows the performance seed and the query plan evidence derive themselves:
# each was folded from helpers of its own, and a rule lost in the folding
# would only show as a benchmark or a seed that quietly says something else.

const my $ITERATIONS       => 3;
const my $TOLERANCE        => 0.25;
const my $FAST_ENOUGH      => 1_000_000;
const my $UNREACHABLE_RATE => 1_000_000_000_000;
const my $MANY_ROWS        => 1_001;
const my $SORT_OK_ROWS     => 1_000;
const my $USERS            => 4;
const my $THREADS          => 4;
const my $POSTS_PER_THREAD => 5;
const my $READ_THREADS     => 3;
const my $READ_POSITION    => 4;
const my $CATALOG_ROWS     => 10;
const my $SCANNED_ROWS     => 50;
const my $LARGE_TABLE_ROWS => 100;
const my $ROUTE            => q{/page};
const my $USER_BIND        => 1;
const my $ROLE_BIND        => 2;
const my $POSITION_BIND    => 2;

# [ user, role ] the seed binds: administrator 1, moderator 2, member 3.
const my @ROLE_OF_USER => ( [ 1, 1 ], [ 2, 2 ], [ 3, 3 ], [ 4, 3 ] );

my $app = Mojolicious->new;
$app->log->level('fatal');
$app->routes->get( $ROUTE => sub ($c) { return $c->render( text => 'ok' ); } );

_test_hypnotoad_route_report();
_test_in_process_route_report();
_test_role_bindings();
_test_read_state();
_test_bitmap_heap_scan_warning();
_test_relation_size();

done_testing();

sub _test_hypnotoad_route_report {
    my $ua = Mojo::UserAgent->new;
    $ua->server->app($app);
    my $runtime = { ua => $ua, base_url => q{} };
    my $options = {
        iterations           => $ITERATIONS,
        warmup               => 0,
        regression_tolerance => $TOLERANCE,
    };
    my $report = _private( 'HypnotoadBenchmark', '_route_report' );

    my $alone = $report->( $runtime, $ROUTE, $options, undef );
    is( $alone->{status}, 'ok', 'a route without a baseline passes' );
    ok( !exists $alone->{comparison}, 'and is compared with nothing' );
    is( $alone->{db_queries}{budget_status},
        'none', 'responses without a budget verdict leave it at none' );

    my $kept = $report->(
        $runtime, $ROUTE, $options,
        {
            p50_ms      => $FAST_ENOUGH,
            p95_ms      => $FAST_ENOUGH,
            p99_ms      => $FAST_ENOUGH,
            req_per_sec => 0,
        }
    );
    is( $kept->{comparison}{status}, 'ok', 'a route as fast as its baseline' );
    is( $kept->{status},             'ok', 'keeps its status' );

    my $slower = $report->(
        $runtime, $ROUTE, $options,
        {
            p50_ms      => $FAST_ENOUGH,
            p95_ms      => $FAST_ENOUGH,
            p99_ms      => $FAST_ENOUGH,
            req_per_sec => $UNREACHABLE_RATE,
        }
    );
    is( $slower->{comparison}{status},
        'fail', 'a route slower than its baseline fails the comparison' );
    is( $slower->{status}, 'fail', 'and fails the route' );
    is_deeply( [ map { $_->{metric} } @{ $slower->{comparison}{violations} } ],
        ['req_per_sec'], 'naming the throughput it lost' );
    is( $slower->{comparison}{baseline}{req_per_sec},
        $UNREACHABLE_RATE, 'beside the baseline it was compared with' );

    return;
}

sub _test_in_process_route_report {
    my $report = _private( 'Benchmark', '_route_report' )->(
        Test::Mojo->new($app),
        $ROUTE, { iterations => $ITERATIONS, warmup => 0 },
    );

    is( $report->{status},   'ok',        'an unobserved route passes' );
    is( $report->{requests}, $ITERATIONS, 'after each request it was asked' );
    is_deeply(
        $report->{db_queries},
        { observed => 0, budget_status => 'not-observed' },
        'and says its queries were not observed, not that they had no budget'
    );

    return;
}

sub _test_role_bindings {
    my $dbh = _seeded_dbh();
    my @roles =
      map { [ $_->[$USER_BIND], $_->[$ROLE_BIND] ] }
      $dbh->binds_of(qr/INSERT \s+ INTO \s+ role_bindings\b/msx);

    is_deeply(
        \@roles,
        [
            map { [ seed_id( user => $_->[0] ), seed_id( role => $_->[1] ) ] }
              @ROLE_OF_USER
        ],
        'the first user administers, the second moderates, the rest are members'
    );

    return;
}

sub _test_read_state {
    my $dbh = _seeded_dbh();
    my @expected;
    for my $user ( 1 .. $USERS ) {
        for my $thread ( 1 .. $READ_THREADS ) {
            push @expected,
              [
                seed_id( user   => $user ),
                seed_id( thread => $thread ),
                $READ_POSITION
              ];
        }
    }

    for my $table (qw(thread_read_state user_read_marker_deltas)) {
        is_deeply(
            [
                map { [ @{$_}[ 0 .. $POSITION_BIND ] ] }
                  $dbh->binds_of(qr/INSERT \s+ INTO \s+ $table\b/msx)
            ],
            \@expected,
            "$table: each user has read three threads to their fourth post"
        );
    }

    return;
}

sub _test_bitmap_heap_scan_warning {
    my $analyze = \&analyze_plan;
    my $plan    = sub ($rows) {
        return {
            Plan => {
                'Node Type' => 'Limit',
                'Plans'     => [
                    {
                        'Node Type'   => 'Bitmap Heap Scan',
                        'Actual Rows' => $rows
                    }
                ],
            },
        };
    };

    my $many = $analyze->( {}, ['SELECT 1'], $plan->($MANY_ROWS) );
    is_deeply( $many->{warnings}, ['bitmap_heap_scan'],
        'a bitmap heap scan over many rows, at any depth, is a warning' );
    is( $many->{status}, 'ok', 'not a violation' );

    is_deeply(
        $analyze->( {}, ['SELECT 1'], $plan->($SORT_OK_ROWS) )->{warnings},
        [], 'one over as many rows as a sort may take is not' );

    return;
}

sub _test_relation_size {
    my $size = \&relation_size;

    is(
        $size->(
            GPForum::Test::BindRecordingDbh->new( row => [$CATALOG_ROWS] ),
            'posts', $SCANNED_ROWS
        ),
        $SCANNED_ROWS,
        'a table holds at least the rows a scan of it read'
    );
    is(
        $size->(
            GPForum::Test::BindRecordingDbh->new( row => [$LARGE_TABLE_ROWS] ),
            'posts',
            $SCANNED_ROWS
        ),
        $LARGE_TABLE_ROWS,
        'and the rows the catalog counts when that is more'
    );
    ok(
        !defined $size->(
            GPForum::Test::BindRecordingDbh->new,
            'unknown', $SCANNED_ROWS
        ),
        'a table the catalog does not know has no size'
    );

    return;
}

sub _seeded_dbh {
    my $options = _private( 'PerformanceSeed', '_options' )->(
        '--users',            $USERS, '--threads', $THREADS,
        '--posts-per-thread', $POSTS_PER_THREAD,
    );
    my $dbh = GPForum::Test::BindRecordingDbh->new;
    _private( 'PerformanceSeed', '_insert_dataset' )
      ->( $dbh, _private( 'PerformanceSeed', '_plan' )->($options) );

    return $dbh;
}

sub _private ( $command, $name ) {
    return "GPForum::Command::$command"->can($name)
      // croak "no GPForum::Command::${command}::$name";
}

1;
