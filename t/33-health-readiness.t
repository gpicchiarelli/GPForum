package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::Readiness;
use GPForum::Test::FailReadinessSchema;
use GPForum::Test::ReadinessRuntime;
use GPForum::Test::ReadinessSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 8;
const my $CHECK_COUNT    => 4;

plan tests => $EXPECTED_TESTS;

my $ready = GPForum::Service::Operations::Readiness->new(
    environment => 'test',
    runtime     => GPForum::Test::ReadinessRuntime->new,
    schema      => GPForum::Test::ReadinessSchema->new,
)->check;

is( $ready->{status},        'ok',   'readiness succeeds when db checks pass' );
is( $ready->{environment},   'test', 'readiness includes environment' );
is( $ready->{runtime}{mode}, 'test', 'readiness includes runtime' );
is( scalar @{ $ready->{checks} },
    $CHECK_COUNT, 'readiness emits individual checks' );
is( $ready->{checks}[0]{name}, 'database', 'readiness checks database first' );
ok( defined $ready->{latency_ms}, 'readiness reports latency' );

my $failed = GPForum::Service::Operations::Readiness->new(
    environment => 'test',
    runtime     => GPForum::Test::ReadinessRuntime->new,
    schema      => GPForum::Test::FailReadinessSchema->new,
)->check;

is( $failed->{status},            'fail', 'readiness fails when db fails' );
is( $failed->{checks}[0]{status}, 'fail', 'failed check is reported' );

1;
