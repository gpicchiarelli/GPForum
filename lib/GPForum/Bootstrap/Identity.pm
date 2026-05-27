package GPForum::Bootstrap::Identity;

use strict;
use warnings;

use GPForum::Service::Identity::ProfileReader;
use GPForum::Service::Identity::Registration;
use GPForum::Service::Identity::SecurityAudit;
use GPForum::Service::Identity::Store;
use GPForum::Service::Password;
use GPForum::Service::SessionToken;

our $VERSION = '0.001';

sub register {
    my ( undef, %input ) = @_;

    my $application = $input{application};

    _register_identity_helpers($application);
    _configure_session_guard($application);

    return;
}

sub _register_identity_helpers {
    my ($application) = @_;

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
                schema => shift->gp_schema );
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

sub _validate_server_session {
    my ($controller) = @_;

    my $session_id = $controller->session('session_id');
    my $user_id    = $controller->session('user_id');
    return if !defined $session_id || !length $session_id;
    return if !defined $user_id    || !length $user_id;

    my $validation = eval {
        return $controller->gp_identity_store->validate_session(
            {
                session_id => $session_id,
                user_id    => $user_id,
            }
        );
    };
    return if $validation && $validation->{ok};

    _clear_web_session($controller);
    $controller->gp_security_telemetry->record(
        'session_invalidated',
        {
            reason => _session_validation_error($validation),
            route  => _current_route_name($controller),
            status => 401,
        }
    );

    return;
}

sub _clear_web_session {
    my ($controller) = @_;

    my $session = $controller->session;
    delete @{$session}
      {qw(user_id session_id login_rotation session_expires_at_epoch)};
    $controller->session( expires => 1 );

    return;
}

sub _session_validation_error {
    my ($validation) = @_;

    return 'validation_failed' if !$validation;
    return $validation->{error} || 'validation_failed';
}

sub _expire_stale_session {
    my ($controller) = @_;

    my $expires_at = $controller->session('session_expires_at_epoch');
    return if !defined $expires_at;
    return if $expires_at > time;

    _clear_web_session($controller);
    $controller->gp_security_telemetry->record(
        'session_expired',
        {
            route  => _current_route_name($controller),
            status => 401,
        }
    );

    return;
}

sub _current_route_name {
    my ($controller) = @_;

    return eval { return $controller->current_route; } || 'unknown';
}

1;
