package GPForum::Service::Identity::Workflow;

use strict;
use warnings;

use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Service::Identity::Support;

our $VERSION = '0.001';

has logger       => undef;
has mailer       => undef;
has registration => undef;
has store        => undef;
has support      => sub { return GPForum::Service::Identity::Support->new; };

sub register {
    my ( $self, $input ) = @_;

    my $prepared = $self->_prepared_registration($input);
    if ( $prepared->{status} ne 'ok' ) {
        return $prepared;
    }

    return $self->_store_registration( $prepared->{stored} );
}

sub login {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_fields( $input, [qw(identifier password)] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_authenticate($input);
}

sub logout {
    my ( $self, $input ) = @_;

    if ( !length _trim( $input->{session_id} ) ) {
        return _result(
            status => 'ok',
            stored => { skipped => 1 },
        );
    }

    return $self->_store_write(
        sub { return $self->store->revoke_session($input); } );
}

sub request_password_reset {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_fields( $input, ['identifier'] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_token_write( 'password_reset',
        sub { return $self->store->request_password_reset($input); } );
}

sub reset_password {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_fields( $input, [qw(token password)] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_store_write(
        sub { return $self->store->reset_password($input); } );
}

sub change_password {
    my ( $self, $input ) = @_;

    return $self->_store_write(
        sub { return $self->store->change_password($input); } );
}

sub request_email_change {
    my ( $self, $input ) = @_;

    return $self->_token_write( 'email_change',
        sub { return $self->store->request_email_change($input); } );
}

sub request_email_verification {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_fields( $input, ['identifier'] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_token_write( 'email_verification',
        sub { return $self->store->request_email_verification($input); } );
}

sub verify_email {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_fields( $input, ['token'] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_store_write(
        sub { return $self->store->confirm_email_verification($input); } );
}

sub confirm_email_change {
    my ( $self, $input ) = @_;

    return $self->_store_write(
        sub { return $self->store->confirm_email_change($input); } );
}

sub update_preferred_locale {
    my ( $self, $input ) = @_;

    my $invalid =
      $self->_missing_fields( $input, [qw(user_id preferred_locale)] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_store_write(
        sub { return $self->store->update_preferred_locale($input); } );
}

sub update_preferred_theme {
    my ( $self, $input ) = @_;

    my $invalid =
      $self->_missing_fields( $input, [qw(user_id preferred_theme)] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_store_write(
        sub { return $self->store->update_preferred_theme($input); } );
}

sub _prepared_registration {
    my ( $self, $input ) = @_;

    my $evaled =
      $self->_eval_store(
        sub { return $self->registration->prepare($input); } );
    if ( $evaled->{failed} ) {
        return _failed_result();
    }

    return _prepared_result( $evaled->{value} );
}

sub _prepared_result {
    my ($value) = @_;

    if ( !$value ) {
        return _failed_result();
    }
    if ( !$value->{ok} ) {
        return _result(
            errors => $value->{errors},
            status => 'invalid',
            stored => { values => $value->{values} },
        );
    }

    return _result(
        status => 'ok',
        stored => $value,
    );
}

sub _store_registration {
    my ( $self, $prepared ) = @_;

    my $evaled = $self->_eval_store(
        sub {
            return $self->store->create_registration(
                $prepared->{registration} );
        }
    );
    if ( $evaled->{failed} ) {
        return _failed_result();
    }

    return $self->_finish_registration( $prepared, $evaled->{value} );
}

sub _finish_registration {
    my ( $self, $prepared, $created ) = @_;

    my $result = _created_registration( $prepared, $created );
    return $self->_after_registration_mail($result);
}

sub _created_registration {
    my ( $prepared, $created ) = @_;

    if ( !$created || !$created->{ok} ) {
        return _result(
            errors => {
                registration => 'registration request could not be accepted',
            },
            status => 'invalid',
            stored => { values => $prepared->{values} },
        );
    }

    return _result(
        status => 'ok',
        stored => {
            registration => $prepared->{registration},
            user         => $created->{user},
            values       => $prepared->{values},
        },
    );
}

sub _authenticate {
    my ( $self, $input ) = @_;

    my $evaled = $self->_eval_store(
        sub { return $self->store->authenticate_login($input); } );
    if ( $evaled->{failed} ) {
        return _rejected_login();
    }

    return _login_result( $evaled->{value} );
}

sub _login_result {
    my ($value) = @_;

    if ( !$value || !$value->{ok} ) {
        return _login_failure($value);
    }

    return _result(
        status => 'ok',
        stored => $value,
    );
}

sub _login_failure {
    my ($value) = @_;

    if ( $value && ( $value->{error} || q{} ) eq 'unverified' ) {
        return _unverified_login();
    }

    return _rejected_login();
}

sub _unverified_login {
    return _result(
        error  => 'unverified',
        status => 'rejected',
    );
}

sub _token_write {
    my ( $self, $kind, $code ) = @_;

    my $result = $self->_store_write($code);
    return $self->_after_token_mail( $result, $kind );
}

sub _after_token_mail {
    my ( $self, $result, $kind ) = @_;

    if ( !$result->{ok} ) {
        return $result;
    }

    $self->_deliver_token_mail( $result->{stored}, $kind );
    return _public_write_result($result);
}

sub _after_registration_mail {
    my ( $self, $result ) = @_;

    if ( !$result->{ok} ) {
        return $result;
    }

    my $issued = $self->_issue_registration_verification( $result->{stored} );
    $self->_deliver_token_mail( $issued, 'email_verification' );
    return $result;
}

sub _issue_registration_verification {
    my ( $self, $stored ) = @_;

    my $evaled = $self->_eval_store(
        sub {
            return $self->store->request_email_verification(
                {
                    user_id => $self->support->column( $stored->{user}, 'id' ),
                }
            );
        }
    );
    return $self->_registration_mail_payload( $stored, $evaled );
}

sub _registration_mail_payload {
    my ( $self, $stored, $evaled ) = @_;

    my $email = $self->support->column( $stored->{user}, 'email_normalized' );
    if ( $evaled->{failed} || !$evaled->{value} ) {
        return { email_normalized => $email };
    }

    my $value = $evaled->{value};
    $value->{email_normalized} ||= $email;
    return $value;
}

sub _deliver_token_mail {
    my ( $self, $stored, $kind ) = @_;

    if ( !$self->mailer ) {
        return;
    }

    my $input = $self->_mail_input($stored);
    if ( !$input ) {
        return;
    }

    $self->_send_kind_mail( $kind, $input );
    return;
}

sub _mail_input {
    my ( $self, $stored ) = @_;

    my $token = $self->_raw_token($stored);
    my $to    = $self->_mail_address($stored);
    if ( !$token || !$to ) {
        return;
    }

    return { to => $to, token => $token };
}

sub _raw_token {
    my ( undef, $stored ) = @_;

    my $token = $stored->{token} || {};
    return $token->{raw_token};
}

sub _mail_address {
    my ( $self, $stored ) = @_;

    if ( $self->support->has_text( $stored->{email_normalized} ) ) {
        return $stored->{email_normalized};
    }

    my $token = $stored->{token} || {};
    return $token->{email_normalized};
}

sub _send_kind_mail {
    my ( $self, $kind, $input ) = @_;

    if ( $kind eq 'password_reset' ) {
        return $self->_eval_mail(
            sub { return $self->mailer->send_password_reset($input); } );
    }
    if ( $kind eq 'email_change' ) {
        return $self->_eval_mail(
            sub { return $self->mailer->send_email_change($input); } );
    }

    return $self->_eval_mail(
        sub { return $self->mailer->send_email_verification($input); } );
}

sub _eval_mail {
    my ( $self, $code ) = @_;

    my $value = eval { return $code->(); };
    if ($EVAL_ERROR) {
        $self->_log_error("identity mail failed: $EVAL_ERROR");
        return { failed => 1 };
    }

    return { value => $value };
}

sub _public_write_result {
    my ($result) = @_;

    my $stored = $result->{stored} || {};
    my $token  = $stored->{token};
    if ( ref $token eq 'HASH' ) {
        delete $token->{raw_token};
        delete $token->{token_hash};
    }

    return $result;
}

sub _store_write {
    my ( $self, $code ) = @_;

    my $evaled = $self->_eval_store($code);
    if ( $evaled->{failed} ) {
        return _failed_result();
    }

    return _accepted_or_invalid( $evaled->{value} );
}

sub _accepted_or_invalid {
    my ($value) = @_;

    if ( !$value ) {
        return _failed_result();
    }
    if ( !$value->{ok} ) {
        return _result(
            error  => $value->{error},
            errors => $value->{errors},
            status => 'invalid',
            stored => $value,
        );
    }

    return _result(
        status => 'ok',
        stored => $value,
    );
}

sub _missing_fields {
    my ( undef, $input, $names ) = @_;

    my %errors;
    for my $name ( @{$names} ) {
        if ( !length _trim( $input->{$name} ) ) {
            $errors{$name} = "$name is required";
        }
    }
    if (%errors) {
        return _result(
            errors => \%errors,
            status => 'invalid',
        );
    }

    return;
}

sub _eval_store {
    my ( $self, $code ) = @_;

    my $value = eval { return $code->(); };
    if ($EVAL_ERROR) {
        $self->_log_error("identity write failed: $EVAL_ERROR");
        return { failed => 1 };
    }

    return { value => $value };
}

sub _rejected_login {
    return _result(
        error  => 'login request could not be accepted',
        status => 'rejected',
    );
}

sub _failed_result {
    return _result(
        error  => 'identity store failed',
        status => 'failed',
    );
}

sub _result {
    my (%input) = @_;

    return {
        error  => $input{error},
        errors => $input{errors},
        ok     => ( $input{status} || q{} ) eq 'ok' ? 1 : 0,
        status => $input{status} || 'failed',
        stored => $input{stored},
    };
}

sub _trim {
    my ($value) = @_;

    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _log_error {
    my ( $self, $message ) = @_;

    if ( !$self->logger || !$self->logger->can('error') ) {
        return;
    }

    $self->logger->error($message);

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::Workflow - Identity write commands.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = $workflow->login(
        {
            identifier => $identifier,
            password   => $password,
        }
    );

=head1 DESCRIPTION

Application boundary for registration, login, logout, password, email, and
preference writes. Validates required fields, delegates persistence to
C<Identity::Registration> and C<Identity::Store>, delivers identity tokens
through C<Identity::Mailer> when configured, and returns a normalized
result hash without raw tokens. Stores keep transaction, event, audit, and
outbox ownership.

=head1 SUBROUTINES/METHODS

=head2 register

Prepares and stores a registration, hiding duplicate-account details.

=head2 login

Authenticates an identifier and password. Failed credentials are C<rejected>
without enumerating whether the account exists.

=head2 logout

Revokes a server-side session when a session id is present.

=head2 request_password_reset

Starts a password reset for an identifier.

=head2 reset_password

Completes a password reset with a token.

=head2 change_password

Changes the password of an authenticated member.

=head2 request_email_change

Starts an email change for an authenticated member.

=head2 confirm_email_change

Completes an email change with a token.

=head2 request_email_verification

Starts a registration verification resend for an identifier.

=head2 verify_email

Completes registration verification with a token.

=head2 update_preferred_locale

Persists an authenticated member locale preference.

=head2 update_preferred_theme

Persists an authenticated member theme preference.

=head1 DIAGNOSTICS

Returns C<invalid>, C<rejected>, or C<failed> statuses instead of throwing for
expected write outcomes. Unexpected store exceptions are logged and mapped to
C<failed>, except login which maps them to C<rejected>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses registration and identity store services supplied by the composition
root.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Cookie-session rotation remains in the HTTP controller. Locale and theme
cookie writes stay HTTP-specific; persistence goes through this workflow.
Command-id replay is not required; stores keep their existing token and
session idempotency.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
