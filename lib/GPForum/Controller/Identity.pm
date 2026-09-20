package GPForum::Controller::Identity;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use GPForum::Web::CookieSession;
use GPForum::Web::ErrorPayload;
use Mojo::Base 'GPForum::Controller::Identity::Base';
use Time::HiRes qw(time);

our $VERSION = '0.001';

const my $HTTP_ACCEPTED     => 202;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_UNAUTHORIZED => 401;

sub register_form {
    my ($self) = @_;

    return $self->render(
        template   => 'identity/register',
        command_id => $self->gp_id->uuid,
        %{ $self->gp_identity_view_model->register_form },
    );
}

sub register {
    my ($self) = @_;

    my $blocked = $self->identity_post_guard('identity.register');
    if ($blocked) {
        return $blocked;
    }

    return $self->_complete_registration;
}

sub login_form {
    my ($self) = @_;

    return $self->render(
        template   => 'identity/login',
        command_id => $self->gp_id->uuid,
        %{ $self->gp_identity_view_model->login_form },
    );
}

sub login {
    my ($self) = @_;

    my $blocked = $self->identity_post_guard('identity.login');
    if ($blocked) {
        return $blocked;
    }

    return $self->_complete_login;
}

sub logout {
    my ($self) = @_;

    my $blocked = $self->identity_post_guard('identity.logout');
    if ($blocked) {
        return $blocked;
    }

    return $self->_complete_logout;
}

sub _complete_registration {
    my ($self) = @_;

    my $result = $self->gp_identity_workflow->register(
        {
            command_id   => $self->command_id_param,
            display_name => $self->param('display_name'),
            email        => $self->param('email'),
            password     => $self->param('password'),
            username     => $self->param('username'),
        }
    );
    if ( $result->{status} eq 'invalid' ) {
        return $self->_register_form_error( $result->{errors},
            $result->{stored}{values} );
    }
    if ( !$result->{ok} ) {
        return $self->identity_write_failure($result);
    }

    return $self->render(
        template     => 'identity/register_accepted',
        status       => $HTTP_ACCEPTED,
        registration => $result->{stored}{registration},
    );
}

sub _register_form_error {
    my ( $self, $errors, $values ) = @_;

    return $self->render(
        template   => 'identity/register',
        command_id => $self->gp_id->uuid,
        status     => $HTTP_BAD_REQUEST,
        %{
            $self->gp_identity_view_model->register_form(
                errors => $errors,
                values => $values,
            )
        },
    );
}

sub _complete_login {
    my ($self) = @_;

    my $result = $self->gp_identity_workflow->login(
        {
            command_id      => $self->command_id_param,
            identifier      => $self->param('identifier'),
            password        => $self->param('password'),
            request_address => $self->request_address,
            user_agent      => $self->req->headers->user_agent || 'unknown',
        }
    );
    if ( $result->{status} eq 'invalid' ) {
        return $self->_login_form_error( $result->{errors} );
    }
    if ( $self->_unverified_login_result($result) ) {
        return $self->_unverified_login;
    }

    return $self->_finish_login($result);
}

sub _finish_login {
    my ( $self, $result ) = @_;

    if ( $result->{ok} ) {
        return $self->_accept_login( $result->{stored} );
    }
    if ( ( $result->{status} || q{} ) eq 'failed' ) {
        return $self->identity_unavailable;
    }

    return $self->_invalid_login;
}

sub _accept_login {
    my ( $self, $authenticated ) = @_;

    $self->_apply_login_session($authenticated);
    $self->_record_identity_audit(
        'record_login_request',
        {
            actor_id        => $authenticated->{user_id},
            identifier      => $self->param('identifier'),
            outcome         => 'accepted',
            request_address => $self->request_address,
        }
    );

    return $self->render(
        template => 'identity/login_accepted',
        status   => $HTTP_ACCEPTED,
    );
}

sub _login_form_error {
    my ( $self, $errors ) = @_;

    return $self->_render_login_form( $HTTP_BAD_REQUEST, $errors );
}

sub _complete_logout {
    my ($self) = @_;

    my $result = $self->_logout_result;
    if ( !$result->{ok} ) {
        return $self->identity_write_failure($result);
    }

    return $self->_accept_logout;
}

sub _logout_result {
    my ($self) = @_;

    return $self->gp_identity_workflow->logout(
        {
            command_id => $self->command_id_param,
            session_id => $self->session('session_id'),
            user_id    => $self->current_user_id,
        }
    );
}

sub _accept_logout {
    my ($self) = @_;

    $self->_record_identity_audit(
        'record_logout_request',
        {
            actor_id        => $self->current_user_id,
            request_address => $self->request_address,
        }
    );
    $self->session( expires => 1 );

    return $self->render(
        template => 'identity/logout_accepted',
        status   => $HTTP_ACCEPTED,
    );
}

sub _apply_login_session {
    my ( $self, $authenticated ) = @_;

    my $cookies          = GPForum::Web::CookieSession->new;
    my $preferred_locale = $self->login_preferred_locale($authenticated);
    my $preferred_theme  = $self->login_preferred_theme($authenticated);
    $cookies->replace_login(
        $self,
        {
            expires_at       => $cookies->expires_at(time),
            preferred_locale => $preferred_locale,
            preferred_theme  => $preferred_theme,
            rotation         => $self->gp_id->uuid,
            session_id       => $authenticated->{session_id},
            user_id          => $authenticated->{user_id},
        }
    );
    $self->_apply_login_preference_cookies( $preferred_locale,
        $preferred_theme );
    return;
}

sub _apply_login_preference_cookies {
    my ( $self, $preferred_locale, $preferred_theme ) = @_;

    if ( defined $preferred_locale ) {
        $self->set_locale_cookie($preferred_locale);
    }
    if ( defined $preferred_theme ) {
        $self->set_theme_cookie($preferred_theme);
    }

    return;
}

sub _record_identity_audit {
    my ( $self, $method, $input ) = @_;

    my $result =
      eval { return $self->gp_identity_security_audit->$method($input); };
    if ( !$result ) {
        $self->_warn_eval('identity audit degraded');
        return;
    }

    return $result;
}

sub _warn_eval {
    my ( $self, $prefix ) = @_;

    if ($EVAL_ERROR) {
        $self->app->log->warn("$prefix: $EVAL_ERROR");
    }

    return;
}

sub _unverified_login_result {
    my ( undef, $result ) = @_;

    if ( !$result->{error} ) {
        return 0;
    }

    return $result->{error} eq 'unverified' ? 1 : 0;
}

sub _unverified_login {
    my ($self) = @_;

    return $self->_render_login_form( $HTTP_UNAUTHORIZED,
        { login => $self->t('auth.login_unverified') },
    );
}

sub _render_login_form {
    my ( $self, $status, $errors ) = @_;

    return $self->render(
        template   => 'identity/login',
        command_id => $self->gp_id->uuid,
        status     => $status,
        %{
            $self->gp_identity_view_model->login_form(
                errors => $errors,
                values => {
                    identifier => $self->param('identifier') || q{},
                },
            )
        },
    );
}

sub _invalid_login {
    my ($self) = @_;

    $self->_record_security_event(
        'auth_denial',
        {
            action => 'identity.login',
            status => $HTTP_UNAUTHORIZED,
        }
    );

    if ( $self->_wants_json ) {
        return $self->render(
            json   => GPForum::Web::ErrorPayload->identity_invalid_login,
            status => $HTTP_UNAUTHORIZED,
        );
    }

    return $self->_render_login_form( $HTTP_UNAUTHORIZED,
        { login => 'login request could not be accepted' },
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Identity - Registration, login, and logout.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/register')->to('Identity#register_form');

=head1 DESCRIPTION

Handles public registration and session lifecycle. Cookie-session duration
lives on L<GPForum::Web::CookieSession>. Password, email, settings, and
profile routes live in sibling controllers.

=head1 SUBROUTINES/METHODS

=head2 register_form

Renders the registration form.

=head2 register

Creates a registration after CSRF and rate-limit checks.

=head2 login_form

Renders the login form.

=head2 login

Authenticates a member and establishes a server session.

=head2 logout

Revokes the current session. Requires C<command_id>.

=head1 DIAGNOSTICS

Invalid CSRF tokens render C<403>; invalid submitted forms render C<400>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses identity helpers registered during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Identity::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Password reset, email change, settings, and profile rendering are owned by
sibling identity controllers.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
