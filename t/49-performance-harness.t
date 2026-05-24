package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Test::More;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 9;

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
