package GPForum::Controller::Identity::Verification;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'GPForum::Controller::Identity::Base';

our $VERSION = '0.001';

const my $HTTP_ACCEPTED    => 202;
const my $HTTP_BAD_REQUEST => 400;

sub email_verify_request_form {
    my ($self) = @_;

    return $self->render(
        template => 'identity/email_verify_request',
        %{ $self->gp_identity_view_model->email_verify_request_form },
    );
}

sub request_email_verification {
    my ($self) = @_;

    my $guard = $self->identity_post_guard('identity.email_verify');
    if ($guard) {
        return $guard;
    }

    return $self->_submit_verification_request;
}

sub email_verify_form {
    my ($self) = @_;

    return $self->render(
        template => 'identity/email_verify',
        %{
            $self->gp_identity_view_model->email_verify_form(
                values => { token => $self->param('token') || q{} },
            )
        },
    );
}

sub verify_email {
    my ($self) = @_;

    my $guard = $self->identity_post_guard('identity.email_verify');
    if ($guard) {
        return $guard;
    }

    return $self->_submit_verification;
}

sub _submit_verification_request {
    my ($self) = @_;

    my $result = $self->gp_identity_workflow->request_email_verification(
        {
            identifier      => $self->param('identifier'),
            request_address => $self->request_address,
        }
    );
    if ( $result->{status} eq 'invalid' ) {
        return $self->_verification_request_form_error( $result->{errors} );
    }
    if ( !$result->{ok} ) {
        return $self->identity_system_failure;
    }

    return $self->render(
        template => 'identity/email_verify_requested',
        status   => $HTTP_ACCEPTED,
    );
}

sub _submit_verification {
    my ($self) = @_;

    my $result =
      $self->gp_identity_workflow->verify_email(
        { token => $self->param('token') } );
    if ( $result->{status} eq 'invalid' ) {
        return $self->_verification_form_error;
    }
    if ( !$result->{ok} ) {
        return $self->identity_system_failure;
    }

    return $self->render(
        template => 'identity/email_verified',
        status   => $HTTP_ACCEPTED,
    );
}

sub _verification_request_form_error {
    my ( $self, $errors ) = @_;

    return $self->render(
        template => 'identity/email_verify_request',
        status   => $HTTP_BAD_REQUEST,
        %{
            $self->gp_identity_view_model->email_verify_request_form(
                errors => $errors,
                values => { identifier => $self->param('identifier') || q{} },
            )
        },
    );
}

sub _verification_form_error {
    my ($self) = @_;

    return $self->identity_bad_request;
}

1;

__END__

=head1 NAME

GPForum::Controller::Identity::Verification - Registration email verification.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/email/verify')->to('Identity::Verification#email_verify_request_form');

=head1 DESCRIPTION

Handles registration verification resend and token confirmation. CSRF stays
plaintext through L<GPForum::Web::IdentityAccess>.

=head1 SUBROUTINES/METHODS

=head2 email_verify_request_form

Renders the verification resend form.

=head2 request_email_verification

Accepts an identifier and starts a verification resend.

=head2 email_verify_form

Renders the verification form for a token.

=head2 verify_email

Completes registration verification with a token.

=head1 DIAGNOSTICS

Invalid CSRF tokens render C<403>; invalid forms render C<400>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses identity helpers registered during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Identity::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Resend success does not reveal whether the identifier exists.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
