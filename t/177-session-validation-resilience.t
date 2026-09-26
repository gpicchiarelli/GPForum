# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';

use GPForum::Bootstrap::Identity;
use Mojolicious;

our $VERSION = '0.001';

package Local::Telemetry;

use Mojo::Base -base;

has events => sub { return []; };

sub record {
    my ( $self, $event, $metadata ) = @_;

    push @{ $self->events }, { event => $event, metadata => $metadata };

    return;
}

sub event_names {
    my ($self) = @_;

    return [ map { $_->{event} } @{ $self->events } ];
}

package Local::BrokenStore;

use Carp qw(croak);
use Mojo::Base -base;

has broken => 1;
has calls  => 0;

sub validate_session {
    my ($self) = @_;

    $self->calls( $self->calls + 1 );
    croak 'session store unavailable' if $self->broken;

    return { ok => 1 };
}

package Local::Schema;

use Mojo::Base -base;

package main;

const my $HTTP_OK          => 200;
const my $HTTP_UNAVAILABLE => 503;

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
        status => 503,
    },
    'the store failure is recorded as a service availability problem'
);

$store->broken(0);
$test->get_ok('/__session/guarded')->status_is($HTTP_OK)->content_is('user-1');
is( $store->calls, 2, 'the cookie survives the failure and serves again' );

done_testing();

sub _test_application {
    my $application = Mojolicious->new;
    my $store       = Local::BrokenStore->new;
    my $telemetry   = Local::Telemetry->new;

    $application->secrets( ['session-validation-resilience-test'] );
    $application->helper( gp_schema => sub { return Local::Schema->new; } );
    $application->helper( gp_security_telemetry => sub { return $telemetry; } );

    GPForum::Bootstrap::Identity->register( application => $application );
    _register_test_routes($application);

    return ( Test::Mojo->new($application), $store, $telemetry );
}

sub _register_test_routes {
    my ($application) = @_;

    $application->routes->get('/__session/set')->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( user_id                  => 'user-1' );
            $controller->session( session_id               => 'session-1' );
            $controller->session( login_rotation           => 1 );
            $controller->session( session_expires_at_epoch => time + 60 );

            return $controller->render( text => 'set' );
        }
    )->name('session_set');

    $application->routes->get('/__session/guarded')->to(
        cb => sub {
            my ($controller) = @_;

            return $controller->render( text => $controller->session('user_id')
                  || 'none' );
        }
    )->name('session_guarded');

    return;
}

1;
