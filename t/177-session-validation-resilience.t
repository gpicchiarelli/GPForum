# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Identity;
use GPForum::Test::BootstrapIdentitySchema;
use GPForum::Test::BootstrapIdentityTelemetry;
use GPForum::Test::BrokenSessionStore;
use Mojolicious;

our $VERSION = '0.001';

const my $HTTP_OK                  => 200;
const my $HTTP_UNAVAILABLE         => 503;
const my $SESSION_LIFETIME_SECONDS => 60;

my ( $test, $store, $telemetry ) = _test_application();
$test->app->helper( gp_identity_store => sub { return $store; } );

$test->get_ok('/__session/set')->status_is($HTTP_OK);
$test->get_ok( '/__session/guarded' => { Accept => 'application/json' } )
  ->status_is($HTTP_UNAVAILABLE);
unlike( $test->tx->res->body,
    qr/user-1/msx,
    'a session the store could not check is not served as its user' );

is( $store->calls, 1, 'the session guard consults the store once' );
is_deeply(
    $telemetry->event_names,
    ['session_validation_unavailable'],
    'a store failure is reported without invalidating the session'
);
is_deeply(
    $telemetry->events->[0]{metadata},
    {
        reason => 'store_error',
        route  => 'unknown',
        status => $HTTP_UNAVAILABLE,
    },
    'the store failure is recorded as a service availability problem'
);

$store->broken(0);
$test->get_ok('/__session/guarded')->status_is($HTTP_OK)->content_is('user-1');
is( $store->calls, 2, 'the cookie survives the failure and serves again' );

done_testing();

sub _test_application {
    my $application         = Mojolicious->new;
    my $broken_store        = GPForum::Test::BrokenSessionStore->new;
    my $recording_telemetry = GPForum::Test::BootstrapIdentityTelemetry->new;

    $application->secrets( ['session-validation-resilience-test'] );
    $application->helper(
        gp_schema => sub { return GPForum::Test::BootstrapIdentitySchema->new; }
    );
    $application->helper(
        gp_security_telemetry => sub { return $recording_telemetry; } );

    GPForum::Bootstrap::Identity->register( application => $application );
    _register_test_routes($application);

    return ( Test::Mojo->new($application),
        $broken_store, $recording_telemetry );
}

sub _register_test_routes {
    my ($application) = @_;

    $application->routes->get(
        '/__session/set' => sub {
            my ($c) = @_;

            $c->session( user_id        => 'user-1' );
            $c->session( session_id     => 'session-1' );
            $c->session( login_rotation => 1 );
            $c->session(
                session_expires_at_epoch => time + $SESSION_LIFETIME_SECONDS );

            return $c->render( text => 'set' );
        },
        'session_set'
    );

    $application->routes->get(
        '/__session/guarded' => sub {
            my ($c) = @_;

            return $c->render( text => $c->session('user_id') || 'none' );
        },
        'session_guarded'
    );

    return;
}

1;
