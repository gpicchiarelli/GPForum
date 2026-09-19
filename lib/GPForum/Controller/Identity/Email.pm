package GPForum::Controller::Identity::Email;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'GPForum::Controller::Identity::Base';

our $VERSION = '0.001';

const my $HTTP_ACCEPTED => 202;

sub request_email_change {
    my ($self) = @_;

    my $guard = $self->identity_post_guard('identity.email_change');
    if ($guard) {
        return $guard;
    }

    return $self->_submit_email_change;
}

sub email_confirm_form {
    my ($self) = @_;

    return $self->render(
        template => 'identity/email_confirm',
        %{
            $self->gp_identity_view_model->email_confirm_form(
                values => { token => $self->param('token') || q{} },
            )
        },
    );
}

sub confirm_email_change {
    my ($self) = @_;

    my $guard = $self->identity_post_guard('identity.email_change');
    if ($guard) {
        return $guard;
    }

    return $self->_complete_email_change;
}

sub _submit_email_change {
    my ($self) = @_;

    my $user_id = $self->current_user_id;
    if ( !$user_id ) {
        return $self->settings_unauthorized;
    }

    my $result = $self->gp_identity_workflow->request_email_change(
        {
            email           => $self->param('email'),
            request_address => $self->request_address,
            user_id         => $user_id,
        }
    );
    if ( $result->{status} eq 'failed' ) {
        return $self->identity_system_failure;
    }
    if ( !$result->{ok} ) {
        return $self->identity_bad_request;
    }

    $self->flash( success => $self->t('settings.email_change_requested') );
    return $self->redirect_to('settings');
}

sub _complete_email_change {
    my ($self) = @_;

    my $result = $self->gp_identity_workflow->confirm_email_change(
        { token => $self->param('token') } );
    if ( $result->{status} eq 'failed' ) {
        return $self->identity_system_failure;
    }
    if ( !$result->{ok} ) {
        return $self->identity_bad_request;
    }

    return $self->render(
        template => 'identity/email_confirmed',
        status   => $HTTP_ACCEPTED,
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Identity::Email - Email change lifecycle.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->post('/settings/email')->to('Identity::Email#request_email_change');

=head1 DESCRIPTION

Handles authenticated email-change requests and token confirmation.

=head1 SUBROUTINES/METHODS

=head2 request_email_change

Starts an email change for the signed-in member.

=head2 email_confirm_form

Renders the email confirmation form.

=head2 confirm_email_change

Completes an email change with a token.

=head1 DIAGNOSTICS

Unauthenticated requests redirect to login; store failures render C<500>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses identity helpers registered during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Identity::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Email confirmation does not automatically refresh the current session
profile payload.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
