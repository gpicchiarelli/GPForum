# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::More;

our $VERSION = '0.001';

const my $EXPECTED_TESTS   => 22;
const my $MEDIUM_USERS     => 25;
const my $HOT_THREAD_POSTS => 120;

# The default dry-run dataset, by table.
const my %DEFAULT_DATASET => (
    bookmarks  => 5,
    feed_items => 12,
    reports    => 10,
    roles      => 3,
    threads    => 12,
);

plan tests => $EXPECTED_TESTS;

my $benchmark = _capture_command(
    'script/benchmark-http', '--fixture',
    '--iterations',          '1',
    '--warmup',              '0',
    '--route',               '/health',
);
like( $benchmark, qr/mode=fixture/msx,
    'benchmark-http script runs fixture benchmark' );
like( $benchmark, qr/route=\/health/msx,
    'benchmark-http reports requested route' );
like( $benchmark, qr/p50_ms=/msx, 'benchmark-http reports p50 latency' );

my $profile_help = _capture_command( 'script/profile-nytprof', '--help' );
like( $profile_help, qr/profile-nytprof/msx,
    'profile-nytprof script exposes usage' );
like( $profile_help, qr/--route/msx,
    'profile-nytprof usage documents route profiling' );

my $seed_json =
  _capture_command( 'script/seed-performance-data', '--dry-run', '--json' );
my $seed = decode_json($seed_json);
is( $seed->{status}, 'dry-run', 'seed script supports dry-run mode' );
is(
    $seed->{dataset}{threads},
    $DEFAULT_DATASET{threads},
    'seed script reports default threads'
);
is(
    $seed->{routes}{category},
    '/c/018f1001-0001-7000-8000-000000000001',
    'seed script reports deterministic category route'
);
is(
    $seed->{routes}{thread},
    '/t/018f1004-0001-7000-8000-000000000001',
    'seed script reports deterministic thread route'
);
is( $seed->{dataset}{roles},
    $DEFAULT_DATASET{roles}, 'seed includes role catalog' );
is(
    $seed->{dataset}{bookmarks},
    $DEFAULT_DATASET{bookmarks},
    'seed includes bookmarks'
);
is(
    $seed->{dataset}{reports},
    $DEFAULT_DATASET{reports},
    'seed includes reports'
);
is(
    $seed->{dataset}{feed_items},
    $DEFAULT_DATASET{feed_items},
    'seed includes feed items'
);

my $medium_json =
  _capture_command( 'script/seed-benchmark', '--dry-run', '--json',
    '--profile', 'medium' );
my $medium_seed = decode_json($medium_json);
is( $medium_seed->{profile}, 'medium', 'seed alias supports profiles' );
is( $medium_seed->{dataset}{users},
    $MEDIUM_USERS, 'medium profile sizes users' );

my $hot_thread_json = _capture_command(
    'bin/gpforum-seed-benchmark', '--dry-run',
    '--json',                     '--profile',
    'hot-thread'
);
my $hot_thread_seed = decode_json($hot_thread_json);
is( $hot_thread_seed->{dataset}{posts_per_thread},
    $HOT_THREAD_POSTS, 'hot-thread profile creates deep threads' );

my $query_plan_json =
  _capture_command( 'script/query-plan-evidence', '--dry-run', '--json' );
my $query_plan = decode_json($query_plan_json);
is( $query_plan->{status}, 'ok', 'query plan evidence has dry-run mode' );

# Named, not counted: the expected number used to be derived from this file's
# own test count, which matched the endpoint list only by coincidence.
is_deeply(
    [ map { $_->{endpoint} } @{ $query_plan->{endpoints} } ],
    [
        qw(
          home categories category_threads category_threads_signed_in
          thread_view search autocomplete feed notifications outbox_claim
          moderation_queue health_ready metrics home_signed_in home_deep
          category_threads_deep category_threads_deep_signed_in
          thread_view_signed_in thread_view_deep thread_view_deep_signed_in
        )
    ],
    'query plan evidence covers the hot endpoints, signed-in and deep pages'
);
my ($autocomplete_endpoint) =
  grep { $_->{endpoint} eq 'autocomplete' } @{ $query_plan->{endpoints} };
is( $autocomplete_endpoint->{endpoint},
    'autocomplete', 'query plan evidence includes autocomplete' );

my $hotpaths =
  _capture_command( 'script/bench-hotpaths', '--iterations', '1', '--warmup',
    '0', '--route', '/health', );
like( $hotpaths, qr/mode=fixture/msx, 'bench-hotpaths runs fixture gate' );

my $threshold_json = _capture_command(
    'script/benchmark-http', '--fixture',
    '--check',               '--json',
    '--iterations',          '1',
    '--warmup',              '0',
    '--route',               '/health',
);
my $threshold_report = decode_json($threshold_json);
is( $threshold_report->{status}, 'ok', 'benchmark check passes smoke route' );
is( $threshold_report->{routes}[0]{status},
    'ok', 'benchmark route exposes threshold status' );

sub _capture_command {
    my (@command) = @_;

    open my $handle, q{-|}, @command
      or croak 'failed to run command';

    my $captured = q{};
    while ( my $line = <$handle> ) {
        $captured .= $line;
    }

    close $handle
      or croak 'command failed';

    return $captured;
}

1;
