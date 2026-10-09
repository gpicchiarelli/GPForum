# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Test::DegradedReadiness;
use GPForum::Test::FailReadiness;
use GPForum::Test::ReadyHealth;

our $VERSION = '0.001';

const my $HTTP_OK                  => 200;
const my $HTTP_SERVICE_UNAVAILABLE => 503;
const my $TOKEN                    => 'health-secret';
const my $PREVIOUS_TOKEN           => 'health-previous';
const my $WRONG_TOKEN              => 'health-secreX';
const my $SLOT                     => 'standby_secret_slot';

# /health/ready rendered its whole report to anyone: every check, its error
# text, replication slot names. /health rendered the environment, process
# counts, sockets and OS limits. Both now answer the status alone unless the
# request carries the metrics token /metrics takes, and the readiness code
# is the same either way, because load balancers act on it.
my $test = Test::Mojo->new('GPForum');
$test->app->helper(
    gp_config => sub {
        return GPForum::Config->new(
            metrics_token           => $TOKEN,
            previous_metrics_tokens => [$PREVIOUS_TOKEN],
        );
    }
);
my $readiness = GPForum::Test::DegradedReadiness->new;
$test->app->helper( gp_readiness => sub { return $readiness; } );

subtest 'an anonymous client reads the readiness status only' => sub {
    $test->get_ok('/health/ready')->status_is($HTTP_OK);
    is_deeply(
        $test->tx->res->json,
        { status => 'degraded', check => 'ready' },
        'status and check, nothing else'
    );
    unlike( $test->tx->res->body, qr/\Q$SLOT\E/msx,
        'no replication slot name' );
};

subtest 'an anonymous client reads an ok status only' => sub {
    my $ready = GPForum::Test::ReadyHealth->new;
    $test->app->helper( gp_readiness => sub { return $ready; } );
    $test->get_ok('/health/ready')->status_is($HTTP_OK);
    is_deeply(
        $test->tx->res->json,
        { status => 'ok', check => 'ready' },
        'status and check, no runtime and no checks'
    );
    $test->get_ok( '/health/ready' => { 'X-GPForum-Metrics-Token' => $TOKEN } )
      ->status_is($HTTP_OK)
      ->json_is( '/checks/0/name' => 'database' );
    $test->app->helper( gp_readiness => sub { return $readiness; } );
};

subtest 'token-dependent bodies are never stored by a cache' => sub {
    for my $path (qw(/health/ready /health)) {
        $test->get_ok($path)->header_is( 'Cache-Control' => 'no-store' );
        $test->get_ok( $path => { 'X-GPForum-Metrics-Token' => $TOKEN } )
          ->header_is( 'Cache-Control' => 'no-store' );
    }
};

subtest 'a wrong token reads the status only, not a 401' => sub {
    $test->get_ok(
        '/health/ready' => { 'X-GPForum-Metrics-Token' => $WRONG_TOKEN } )
      ->status_is($HTTP_OK);
    is_deeply(
        $test->tx->res->json,
        { status => 'degraded', check => 'ready' },
        'the same body as no token'
    );
    $test->get_ok(
        '/health/ready' => { Authorization => "Bearer $WRONG_TOKEN" } )
      ->status_is($HTTP_OK)
      ->json_hasnt('/checks');
};

subtest 'the metrics token reads the full report' => sub {
    $test->get_ok( '/health/ready' => { 'X-GPForum-Metrics-Token' => $TOKEN } )
      ->status_is($HTTP_OK)
      ->json_is( '/status' => 'degraded' );
    $test->json_is( '/checks/1/name'              => 'replication_slots' );
    $test->json_is( '/checks/1/report/problems/0' => "$SLOT is inactive" )
      ->json_is( '/environment' => 'production' );
    $test->get_ok( '/health/ready' => { Authorization => "Bearer $TOKEN" } )
      ->status_is($HTTP_OK)
      ->json_has('/checks');
    $test->get_ok(
        '/health/ready' => { 'X-GPForum-Metrics-Token' => $PREVIOUS_TOKEN } )
      ->status_is($HTTP_OK)
      ->json_has( '/checks',
        'a previous token still reads it during rotation' );
};

subtest 'a failing node answers 503 with or without the token' => sub {
    my $failing = GPForum::Test::FailReadiness->new;
    $test->app->helper( gp_readiness => sub { return $failing; } );
    $test->get_ok('/health/ready')->status_is($HTTP_SERVICE_UNAVAILABLE);
    is_deeply(
        $test->tx->res->json,
        { status => 'fail', check => 'ready' },
        'anonymous: the status only'
    );
    $test->get_ok(
        '/health/ready' => { 'X-GPForum-Metrics-Token' => $WRONG_TOKEN } )
      ->status_is($HTTP_SERVICE_UNAVAILABLE)
      ->json_hasnt('/checks');
    $test->get_ok( '/health/ready' => { 'X-GPForum-Metrics-Token' => $TOKEN } )
      ->status_is($HTTP_SERVICE_UNAVAILABLE)
      ->json_is( '/checks/0/name' => 'database' );
    $test->app->helper( gp_readiness => sub { return $readiness; } );
};

subtest 'the summary is the status alone without the token' => sub {
    $test->get_ok('/health')->status_is($HTTP_OK);
    is_deeply( $test->tx->res->json, { status => 'ok' }, 'anonymous' );
    $test->get_ok( '/health' => { 'X-GPForum-Metrics-Token' => $WRONG_TOKEN } )
      ->status_is($HTTP_OK);
    is_deeply( $test->tx->res->json, { status => 'ok' }, 'wrong token' );
    $test->get_ok( '/health' => { Authorization => "Bearer $TOKEN" } )
      ->status_is($HTTP_OK)
      ->json_is( '/application' => 'GPForum' );
    $test->json_has('/runtime/web_processes')->json_has('/os');
};

subtest 'liveness names nothing and needs no token' => sub {
    $test->get_ok('/health/live')->status_is($HTTP_OK);
    is_deeply( [ sort keys %{ $test->tx->res->json } ],
        [qw(check status time)], 'status, check and time only' );
};

subtest 'with no token configured the reports stay open, as /metrics' => sub {
    my $open = Test::Mojo->new('GPForum');
    $open->app->helper( gp_readiness => sub { return $readiness; } );
    $open->get_ok('/health/ready')
      ->status_is($HTTP_OK)
      ->json_is( '/checks/1/name' => 'replication_slots' );
    $open->get_ok('/health')
      ->status_is($HTTP_OK)
      ->json_is( '/application' => 'GPForum' );
};

done_testing();

1;
