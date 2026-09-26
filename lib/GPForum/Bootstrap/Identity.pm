# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Bootstrap::Identity;

use strict;
use warnings;
use feature 'signatures';

use Const::Fast;
use English qw(-no_match_vars);

use GPForum::Service::Identity::Mailer;
use GPForum::Service::Identity::ProfileReader;
use GPForum::Service::Identity::Registration;
use GPForum::Service::Identity::SecurityAudit;
use GPForum::Service::Identity::Store;
use GPForum::Service::Identity::Workflow;
use GPForum::Service::Password;
use GPForum::Service::SessionToken;
use GPForum::Web::Access;
use GPForum::Web::CookieSession;
use GPForum::Web::Guard;

our $VERSION = '0.001';

const my $HTTP_UNAUTHORIZED        => 401;
const my $HTTP_SERVICE_UNAVAILABLE => 503;

sub register ( $, %input ) {
    my $application = $input{application};

    _register_identity_helpers( $application, $input{config} );
    _configure_session_guard($application);

    return;
}

sub _register_identity_helpers {
    my ( $application, $config ) = @_;

    my $touch_interval =
      $config ? $config->session_touch_interval_seconds : undef;

    $application->helper(
        gp_password => sub { return GPForum::Service::Password->new; } );
    $application->helper(
        gp_session_token => sub { return GPForum::Service::SessionToken->new; }
    );
    $application->helper( gp_registration =>
          sub { return GPForum::Service::Identity::Registration->new; } );
    $application->helper(
        gp_identity_security_audit => sub {
            my ($controller) = @_;

            return GPForum::Service::Identity::SecurityAudit->new(
                schema => $controller->gp_schema );
        }
    );
    $application->helper(
        gp_identity_store => sub {
            return GPForum::Service::Identity::Store->new(
                schema                         => shift->gp_schema,
                session_touch_interval_seconds => $touch_interval,
            );
        }
    );
    $application->helper(
        gp_identity_mailer => sub {
            my ($controller) = @_;

            return GPForum::Service::Identity::Mailer->from_config(
                $controller->gp_config );
        }
    );
    $application->helper(
        gp_identity_workflow => sub {
            my ($controller) = @_;

            return GPForum::Service::Identity::Workflow->new(
                command_idempotency => $controller->gp_command_idempotency,
                logger              => $controller->app->log,
                registration        => $controller->gp_registration,
                store               => $controller->gp_identity_store,
            );
        }
    );
    $application->helper(
        gp_profile_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Identity::ProfileReader->new(
                schema => $controller->gp_schema );
        }
    );

    return;
}

sub _configure_session_guard {
    my ($application) = @_;

    $application->hook(
        before_dispatch => sub {
            my ($controller) = @_;

            _expire_stale_session($controller);
            _validate_server_session($controller);
        }
    );

    return;
}

sub _validate_server_session ($controller) {
    my $undefined;

    my $cookies = GPForum::Web::CookieSession->new;
    if ( !$cookies->has_server_session($controller) ) {
        return $undefined;
    }

    my $validation = eval {
        return $controller->gp_identity_store->validate_session(
            {
                session_id    => $controller->session('session_id'),
                session_token => $controller->session('session_token'),
                user_id => GPForum::Web::Access->new->user_id($controller),
            }
        );
    };
    my $error = $EVAL_ERROR;
    if ($error) {

        # A store failure is not evidence that the session is invalid, so the
        # cookie is kept; but nor is it evidence that the session is valid, so
        # the request is not served as its user. It used to be: a session
        # revoked by a password change or a sign-out everywhere acted again
        # whenever the check failed and the page's own queries did not.
        _record_validation_error($controller);
        return GPForum::Web::Guard->new->service_unavailable($controller);
    }
    if ( $validation && $validation->{ok} ) {
        return $undefined;
    }

    return _invalidate_session( $controller, $cookies, $validation );
}

sub _record_validation_error ($controller) {
    $controller->gp_security_telemetry->record(
        'session_validation_unavailable',
        {
            reason => 'store_error',
            route  => _current_route_name($controller),
            status => $HTTP_SERVICE_UNAVAILABLE,
        }
    );

    return;
}

sub _invalidate_session ( $controller, $cookies, $validation ) {
    $cookies->clear($controller);
    $controller->gp_security_telemetry->record(
        'session_invalidated',
        {
            reason => $cookies->validation_reason($validation),
            route  => _current_route_name($controller),
            status => $HTTP_UNAUTHORIZED,
        }
    );

    return;
}

sub _expire_stale_session ($controller) {
    my $cookies = GPForum::Web::CookieSession->new;
    if ( !$cookies->expired( $controller, time ) ) {
        return;
    }

    $cookies->clear($controller);
    $controller->gp_security_telemetry->record(
        'session_expired',
        {
            route  => _current_route_name($controller),
            status => $HTTP_UNAUTHORIZED,
        }
    );

    return;
}

sub _current_route_name ($controller) {
    return eval { return $controller->current_route; } || 'unknown';
}

1;
