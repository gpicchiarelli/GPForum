# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Test::Mojo;
use Test::More;

use lib 'lib';

use GPForum::Bootstrap::Identity;
use Mojolicious;

our $VERSION = '0.001';

can_ok( 'GPForum::Bootstrap::Identity', 'register' );

my ($helper_test) = _test_application();
my $controller = $helper_test->app->build_controller;

isa_ok( $controller->gp_password,      'GPForum::Service::Password' );
isa_ok( $controller->gp_session_token, 'GPForum::Service::SessionToken' );
isa_ok( $controller->gp_registration,
    'GPForum::Service::Identity::Registration' );
isa_ok(
    $controller->gp_identity_security_audit,
    'GPForum::Service::Identity::SecurityAudit'
);
isa_ok( $controller->gp_identity_store, 'GPForum::Service::Identity::Store' );
isa_ok( $controller->gp_profile_reader,
    'GPForum::Service::Identity::ProfileReader' );

my ( $valid_test, $valid_store ) = _test_application();
$valid_test->app->helper( gp_identity_store => sub { return $valid_store; } );
$valid_test->get_ok('/__identity/set/valid')->status_is(200);
$valid_test->get_ok('/__identity/guarded')
  ->status_is(200)
  ->content_is('user-1');
is( scalar @{ $valid_store->validations },
    1, 'identity guard validates live server session once' );

my ( $invalid_test, $invalid_store, $invalid_telemetry ) = _test_application();
$invalid_test->app->helper(
    gp_identity_store => sub { return $invalid_store; } );
$invalid_test->get_ok('/__identity/set/invalid')->status_is(200);
$invalid_test->get_ok('/__identity/guarded')
  ->status_is(200)
  ->content_is('none');
is( scalar @{ $invalid_store->validations },
    1, 'identity guard validates invalid server session once' );
is_deeply(
    $invalid_telemetry->events->[0],
    {
        event    => 'session_invalidated',
        metadata => {
            reason => 'revoked',
            route  => 'unknown',
            status => 401,
        },
    },
    'identity guard records invalid session telemetry'
);

my ( $expired_test, $expired_store, $expired_telemetry ) = _test_application();
$expired_test->app->helper(
    gp_identity_store => sub { return $expired_store; } );
$expired_test->get_ok('/__identity/set/expired')->status_is(200);
$expired_test->get_ok('/__identity/guarded')
  ->status_is(200)
  ->content_is('none');
is( scalar @{ $expired_store->validations },
    0, 'identity guard does not validate after local session expiry' );
is_deeply(
    $expired_telemetry->events->[0],
    {
        event    => 'session_expired',
        metadata => {
            route  => 'unknown',
            status => 401,
        },
    },
    'identity guard records expired session telemetry'
);

done_testing();

sub _test_application {
    my $application = Mojolicious->new;
    my $store       = GPForum::Test::BootstrapIdentityStore->new;
    my $telemetry   = GPForum::Test::BootstrapIdentityTelemetry->new;

    $application->secrets( ['bootstrap-identity-test'] );
    $application->helper(
        gp_schema => sub {
            return GPForum::Test::BootstrapIdentitySchema->new;
        }
    );
    $application->helper(
        gp_security_telemetry => sub {
            return $telemetry;
        }
    );

    GPForum::Bootstrap::Identity->register( application => $application );
    _register_test_routes($application);

    return ( Test::Mojo->new($application), $store, $telemetry );
}

sub _register_test_routes {
    my ($application) = @_;

    $application->routes->get('/__identity/set/:state')->to(
        cb => sub {
            my ($controller) = @_;

            my $state = $controller->param('state');
            $controller->session( user_id        => 'user-1' );
            $controller->session( session_id     => $state );
            $controller->session( login_rotation => 1 );
            $controller->session(
                session_expires_at_epoch => $state eq 'expired'
                ? time - 1
                : time + 60
            );

            return $controller->render( text => 'set' );
        }
    )->name('identity_set_session');

    $application->routes->get('/__identity/guarded')->to(
        cb => sub {
            my ($controller) = @_;

            return $controller->render( text => $controller->session('user_id')
                  || 'none' );
        }
    )->name('identity_guarded');

    return;
}

package GPForum::Test::BootstrapIdentityStore;

sub new {
    my ($class) = @_;

    return bless { validations => [] }, $class;
}

sub validations {
    my ($self) = @_;

    return $self->{validations};
}

sub validate_session {
    my ( $self, $input ) = @_;

    push @{ $self->validations }, $input;
    return { ok => 1 } if $input->{session_id} eq 'valid';

    return { ok => 0, error => 'revoked' };
}

package GPForum::Test::BootstrapIdentityTelemetry;

sub new {
    my ($class) = @_;

    return bless { events => [] }, $class;
}

sub events {
    my ($self) = @_;

    return $self->{events};
}

sub record {
    my ( $self, $event, $metadata ) = @_;

    push @{ $self->events },
      {
        event    => $event,
        metadata => $metadata,
      };

    return;
}

package GPForum::Test::BootstrapIdentitySchema;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

1;
