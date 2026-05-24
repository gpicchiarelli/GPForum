package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::More;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 20;

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
is( $seed->{status},           'dry-run', 'seed script supports dry-run mode' );
is( $seed->{dataset}{threads}, 12, 'seed script reports default threads' );
like(
    $seed->{routes}{category},
    qr{\A /c/018f1001-0001-7000-8000-000000000001 \z}msx,
    'seed script reports deterministic category route'
);
like(
    $seed->{routes}{thread},
    qr{\A /t/018f1004-0001-7000-8000-000000000001 \z}msx,
    'seed script reports deterministic thread route'
);
is( $seed->{dataset}{roles},      3,  'seed includes role catalog' );
is( $seed->{dataset}{bookmarks},  5,  'seed includes bookmarks' );
is( $seed->{dataset}{reports},    10, 'seed includes reports' );
is( $seed->{dataset}{feed_items}, 12, 'seed includes feed items' );

my $medium_json =
  _capture_command( 'script/seed-benchmark', '--dry-run', '--json',
    '--profile', 'medium' );
my $medium_seed = decode_json($medium_json);
is( $medium_seed->{profile},        'medium', 'seed alias supports profiles' );
is( $medium_seed->{dataset}{users}, 25,       'medium profile sizes users' );

my $hot_thread_json = _capture_command(
    'bin/gpforum-seed-benchmark', '--dry-run',
    '--json',                     '--profile',
    'hot-thread'
);
my $hot_thread_seed = decode_json($hot_thread_json);
is( $hot_thread_seed->{dataset}{posts_per_thread},
    120, 'hot-thread profile creates deep threads' );

my $query_plan_json =
  _capture_command( 'script/query-plan-evidence', '--dry-run', '--json' );
my $query_plan = decode_json($query_plan_json);
is( $query_plan->{status}, 'ok', 'query plan evidence has dry-run mode' );
is( scalar @{ $query_plan->{endpoints} },
    10, 'query plan evidence covers hot endpoints' );

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
