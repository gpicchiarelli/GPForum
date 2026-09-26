# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Identity::Password;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'GPForum::Controller::Identity::Base', -signatures;

our $VERSION = '0.001';

const my $HTTP_ACCEPTED    => 202;
const my $HTTP_BAD_REQUEST => 400;

sub password_reset_request_form ($self) {
    return $self->render(
        template   => 'identity/password_reset_request',
        command_id => $self->gp_id->uuid,
        %{ $self->gp_identity_view_model->password_reset_request_form },
    );
}

sub request_password_reset ($self) {
    my $guard = $self->identity_post_guard('identity.password_reset');
    if ($guard) {
        return $guard;
    }

    return $self->_submit_password_reset_request;
}

sub password_reset_form ($self) {
    return $self->render(
        template   => 'identity/password_reset_form',
        command_id => $self->gp_id->uuid,
        %{
            $self->gp_identity_view_model->password_reset_form(
                values => { token => $self->param('token') || q{} },
            )
        },
    );
}

sub reset_password ($self) {
    my $guard = $self->identity_post_guard('identity.password_reset');
    if ($guard) {
        return $guard;
    }

    return $self->_submit_password_reset;
}

sub change_password ($self) {
    my $guard = $self->identity_post_guard('identity.password_change');
    if ($guard) {
        return $guard;
    }

    return $self->_submit_password_change;
}

sub _submit_password_reset_request ($self) {
    my $result = $self->gp_identity_workflow->request_password_reset(
        {
            command_id      => $self->command_id_param,
            identifier      => $self->param('identifier'),
            request_address => $self->request_address,
        }
    );
    if ( $result->{status} eq 'invalid' ) {
        return $self->_password_reset_request_form_error( $result->{errors} );
    }
    if ( !$result->{ok} ) {
        return $self->identity_write_failure($result);
    }

    return $self->render(
        template => 'identity/password_reset_requested',
        status   => $HTTP_ACCEPTED,
    );
}

sub _submit_password_reset ($self) {
    my $result = $self->gp_identity_workflow->reset_password(
        {
            command_id => $self->command_id_param,
            password   => $self->param('password'),
            token      => $self->param('token'),
        }
    );
    if ( $result->{status} eq 'invalid' ) {
        return $self->_render_password_reset_error(
            $self->_reset_form_errors($result) );
    }
    if ( !$result->{ok} ) {
        return $self->identity_write_failure($result);
    }

    return $self->render(
        template => 'identity/password_reset_completed',
        status   => $HTTP_ACCEPTED,
    );
}

sub _submit_password_change ($self) {
    my $user_id = $self->current_user_id;
    if ( !$user_id ) {
        return $self->settings_unauthorized;
    }

    # Naming the current session lets the store evict the user's other devices
    # without signing them out of the browser they just used.
    my $result = $self->gp_identity_workflow->change_password(
        {
            command_id       => $self->command_id_param,
            current_password => $self->param('current_password'),
            keep_session_id  => $self->session('session_id'),
            new_password     => $self->param('new_password'),
            user_id          => $user_id,
        }
    );
    if ( !$result->{ok} ) {
        return $self->identity_write_failure($result);
    }

    $self->flash( success => $self->t('settings.password_changed') );
    return $self->redirect_to('settings');
}

sub _reset_form_errors ( $, $result ) {
    if ( $result->{errors} ) {
        return $result->{errors};
    }

    return { reset => 'password reset request could not be accepted' };
}

sub _password_reset_request_form_error ( $self, $errors ) {
    return $self->render(
        template   => 'identity/password_reset_request',
        command_id => $self->gp_id->uuid,
        status     => $HTTP_BAD_REQUEST,
        %{
            $self->gp_identity_view_model->password_reset_request_form(
                errors => $errors,
                values => { identifier => $self->param('identifier') || q{} },
            )
        },
    );
}

sub _render_password_reset_error ( $self, $errors ) {
    return $self->render(
        template   => 'identity/password_reset_form',
        command_id => $self->gp_id->uuid,
        status     => $HTTP_BAD_REQUEST,
        %{
            $self->gp_identity_view_model->password_reset_form(
                errors => $errors,
                values => { token => $self->param('token') || q{} },
            )
        },
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Identity::Password - Password reset and change.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->post('/password/reset')->to('Identity::Password#request_password_reset');

=head1 DESCRIPTION

Handles password reset requests, reset completion, and authenticated
password changes.

=head1 SUBROUTINES/METHODS

=head2 password_reset_request_form

Renders the password reset request form.

=head2 request_password_reset

Accepts an identifier and starts a password reset.

=head2 password_reset_form

Renders the reset form for a token.

=head2 reset_password

Completes a password reset with a token.

=head2 change_password

Changes the password of the signed-in member.

=head1 DIAGNOSTICS

Invalid CSRF tokens render C<403>; invalid forms render C<400>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses identity helpers registered during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Identity::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Reset request success does not reveal whether the identifier exists.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
