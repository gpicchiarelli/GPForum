package GPForum::Service::Identity::Workflow;

use strict;
use warnings;

use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Service::Identity::Support;

our $VERSION = '0.001';

has command_idempotency => undef;
has logger              => undef;
has registration        => undef;
has store               => undef;
has support => sub { return GPForum::Service::Identity::Support->new; };

sub register {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_fields( $input, ['command_id'] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_write(
        {
            actor_id     => undef,
            command_id   => $input->{command_id},
            command_type => 'identity.register',
            request      => {
                email    => _trim( $input->{email} ),
                username => _trim( $input->{username} ),
            },
            run => sub { return $self->_register_account($input); },
        }
    );
}

sub login {
    my ( $self, $input ) = @_;

    my $invalid =
      $self->_missing_fields( $input, [qw(command_id identifier password)] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_write(
        {
            actor_id     => undef,
            command_id   => $input->{command_id},
            command_type => 'identity.login',
            request      => { identifier => _trim( $input->{identifier} ) },
            run          => sub { return $self->_login_account($input); },
        }
    );
}

sub logout {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_fields( $input, ['command_id'] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_logout($input);
}

sub _commanded_logout {
    my ( $self, $input ) = @_;

    return $self->_commanded_write(
        {
            actor_id     => $input->{user_id},
            command_id   => $input->{command_id},
            command_type => 'identity.logout',
            request      => {
                session_id => _trim( $input->{session_id} ),
                user_id    => _trim( $input->{user_id} ),
            },
            run => sub { return $self->_logout_store($input); },
        }
    );
}

sub _logout_store {
    my ( $self, $input ) = @_;

    if ( !length _trim( $input->{session_id} ) ) {
        return _result(
            status => 'ok',
            stored => { skipped => 1 },
        );
    }

    return $self->_public_consume_result(
        sub { return $self->store->revoke_session($input); } );
}

sub request_password_reset {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_fields( $input, [qw(command_id identifier)] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_token_write(
        {
            actor_id     => undef,
            command_id   => $input->{command_id},
            command_type => 'identity.password_reset',
            request      => { identifier => _trim( $input->{identifier} ) },
            run          => sub {
                return $self->store->request_password_reset($input);
            },
        }
    );
}

sub reset_password {
    my ( $self, $input ) = @_;

    return $self->_token_consume_write(
        {
            command_type => 'identity.password_reset_complete',
            extra_fields => ['password'],
            input        => $input,
            run          => sub {
                return $self->store->reset_password($input);
            },
        }
    );
}

sub change_password {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_fields( $input,
        [qw(command_id current_password new_password user_id)] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_write(
        {
            actor_id     => $input->{user_id},
            command_id   => $input->{command_id},
            command_type => 'identity.password_change',
            request      => { user_id => $input->{user_id} },
            run          => sub {
                return $self->_public_consume_result(
                    sub { return $self->store->change_password($input); } );
            },
        }
    );
}

sub request_email_change {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_fields( $input, ['command_id'] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_token_write(
        {
            actor_id     => $input->{user_id},
            command_id   => $input->{command_id},
            command_type => 'identity.email_change',
            request      => {
                email   => _trim( $input->{email} ),
                user_id => $input->{user_id},
            },
            run => sub {
                return $self->store->request_email_change($input);
            },
        }
    );
}

sub request_email_verification {
    my ( $self, $input ) = @_;

    my $invalid = $self->_missing_fields( $input, [qw(command_id identifier)] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_token_write(
        {
            actor_id     => undef,
            command_id   => $input->{command_id},
            command_type => 'identity.email_verification',
            request      => { identifier => _trim( $input->{identifier} ) },
            run          => sub {
                return $self->store->request_email_verification($input);
            },
        }
    );
}

sub verify_email {
    my ( $self, $input ) = @_;

    return $self->_token_consume_write(
        {
            command_type => 'identity.email_verification_complete',
            input        => $input,
            run          => sub {
                return $self->store->confirm_email_verification($input);
            },
        }
    );
}

sub confirm_email_change {
    my ( $self, $input ) = @_;

    return $self->_token_consume_write(
        {
            command_type => 'identity.email_change_complete',
            input        => $input,
            run          => sub {
                return $self->store->confirm_email_change($input);
            },
        }
    );
}

sub update_preferred_locale {
    my ( $self, $input ) = @_;

    return $self->_preference_write(
        {
            command_type => 'identity.locale_change',
            field        => 'preferred_locale',
            input        => $input,
            run          => sub {
                return $self->store->update_preferred_locale($input);
            },
        }
    );
}

sub update_preferred_theme {
    my ( $self, $input ) = @_;

    return $self->_preference_write(
        {
            command_type => 'identity.theme_change',
            field        => 'preferred_theme',
            input        => $input,
            run          => sub {
                return $self->store->update_preferred_theme($input);
            },
        }
    );
}

sub _preference_write {
    my ( $self, $job ) = @_;

    my $input = $job->{input};
    my $field = $job->{field};
    my $invalid =
      $self->_missing_fields( $input, [ 'command_id', 'user_id', $field ] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_preference($job);
}

sub _commanded_preference {
    my ( $self, $job ) = @_;

    my $input = $job->{input};
    my $field = $job->{field};
    return $self->_commanded_write(
        {
            actor_id     => $input->{user_id},
            command_id   => $input->{command_id},
            command_type => $job->{command_type},
            request      => {
                $field  => _trim( $input->{$field} ),
                user_id => $input->{user_id},
            },
            run => sub { return $self->_public_preference_result($job); },
        }
    );
}

sub _public_preference_result {
    my ( $self, $job ) = @_;

    my $result = $self->_store_write( $job->{run} );
    if ( !$result->{ok} ) {
        return $result;
    }

    my $field = $job->{field};
    return _result(
        status => 'ok',
        stored => {
            ok     => 1,
            $field => $result->{stored}{$field},
        },
    );
}

sub _register_account {
    my ( $self, $input ) = @_;

    my $prepared = $self->_prepared_registration($input);
    if ( $prepared->{status} ne 'ok' ) {
        return $prepared;
    }

    return $self->_store_registration( $prepared->{stored} );
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

sub _token_consume_write {
    my ( $self, $job ) = @_;

    my $invalid = $self->_missing_fields( $job->{input},
        [ 'command_id', 'token', @{ $job->{extra_fields} || [] } ] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_consume($job);
}

sub _commanded_consume {
    my ( $self, $job ) = @_;

    my $input = $job->{input};
    return $self->_commanded_write(
        {
            actor_id     => undef,
            command_id   => $input->{command_id},
            command_type => $job->{command_type},
            request      => { token => _trim( $input->{token} ) },
            run          => sub {
                return $self->_public_consume_result( $job->{run} );
            },
        }
    );
}

sub _public_consume_result {
    my ( $self, $code ) = @_;

    my $result = $self->_store_write($code);
    if ( !$result->{ok} ) {
        return $result;
    }

    return _result(
        status => 'ok',
        stored => { ok => 1 },
    );
}

sub _login_account {
    my ( $self, $input ) = @_;

    my $result = $self->_authenticate($input);
    if ( !$result->{ok} ) {
        return $result;
    }

    return _result(
        status => 'ok',
        stored => $self->_public_login_stored( $result->{stored} ),
    );
}

sub _authenticate {
    my ( $self, $input ) = @_;

    my $evaled = $self->_eval_store(
        sub { return $self->store->authenticate_login($input); } );
    if ( $evaled->{failed} ) {
        return _failed_result();
    }

    return _login_result( $evaled->{value} );
}

sub _public_login_stored {
    my ( $self, $stored ) = @_;

    $stored ||= {};
    return {
        preferred_locale =>
          $self->_login_preference( $stored, 'preferred_locale' ),
        preferred_theme =>
          $self->_login_preference( $stored, 'preferred_theme' ),
        session_id => $stored->{session_id},
        user_id    => $stored->{user_id},
    };
}

sub _login_preference {
    my ( $self, $stored, $name ) = @_;

    if ( $self->support->has_text( $stored->{$name} ) ) {
        return $stored->{$name};
    }

    return $self->support->column( $stored->{user}, $name );
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
    my ( $self, $code ) = @_;

    my $result = $self->_store_write($code);
    if ( !$result->{ok} ) {
        return $result;
    }

    return _public_write_result($result);
}

sub _commanded_write {
    my ( $self, $job ) = @_;

    if ( !$self->command_idempotency ) {
        return $job->{run}->();
    }

    return $self->_idempotent_token_write($job);
}

sub _commanded_token_write {
    my ( $self, $job ) = @_;

    return $self->_commanded_write(
        {
            actor_id     => $job->{actor_id},
            command_id   => $job->{command_id},
            command_type => $job->{command_type},
            request      => $job->{request},
            run          => sub {
                return $self->_token_write( $job->{run} );
            },
        }
    );
}

sub _idempotent_token_write {
    my ( $self, $job ) = @_;

    my $guarded = eval { return $self->_token_command_guard($job); };
    if ($EVAL_ERROR) {
        $self->_log_error("identity command log failed: $EVAL_ERROR");
        return _failed_result();
    }

    return _token_guard_result($guarded);
}

sub _token_command_guard {
    my ( $self, $job ) = @_;

    return $self->command_idempotency->run(
        {
            actor_id     => $job->{actor_id},
            command_id   => _trim( $job->{command_id} ),
            command_type => $job->{command_type},
            request      => $job->{request} || {},
        },
        sub { return $job->{run}->(); },
        sub {
            my ($result) = @_;
            return $result;
        },
    );
}

sub _token_guard_result {
    my ($guarded) = @_;

    if ( $guarded->{replayed} ) {
        return $guarded->{response};
    }
    if ( $guarded->{recorded} ) {
        return $guarded->{result};
    }

    return _token_guard_failure($guarded);
}

sub _token_guard_failure {
    my ($guarded) = @_;

    if ( $guarded->{invalid} ) {
        return _result(
            errors => { command_id => 'command_id is required' },
            status => 'invalid',
        );
    }

    return _result(
        error  => $guarded->{error},
        status => 'conflict',
    );
}

sub _after_registration_mail {
    my ( $self, $result ) = @_;

    if ( !$result->{ok} ) {
        return $result;
    }

    $self->_issue_registration_verification( $result->{stored} );
    return $result;
}

sub _issue_registration_verification {
    my ( $self, $stored ) = @_;

    return $self->_eval_store(
        sub {
            return $self->store->request_email_verification(
                {
                    user_id => $self->support->column( $stored->{user}, 'id' ),
                }
            );
        }
    );
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
            command_id => $command_id,
            identifier => $identifier,
            password   => $password,
        }
    );

=head1 DESCRIPTION

Application boundary for registration, login, logout, password, email, and
preference writes. Validates required fields, delegates persistence to
C<Identity::Registration> and C<Identity::Store>, and returns a normalized
result hash without raw tokens. Token mail is queued on the identity
outbox by the store in the same transaction as issuance. Registration,
password-reset, email-change, and verification-resend require C<command_id>
and replay from C<command_log> when the helper is present. Registration
request hashes include email and username only, never the password. Login
request hashes include the identifier only, never the password, and the
recorded result is JSON-safe session identity. Token-consume commands
(password-reset complete, email-change complete, and verification complete)
request hashes include the token only, never a new password, and the
recorded result is JSON-safe. Stores keep transaction, event, audit, and
outbox ownership.

=head1 SUBROUTINES/METHODS

=head2 register

Prepares and stores a registration, hiding duplicate-account details.
Requires C<command_id>.

=head2 login

Authenticates an identifier and password. Requires C<command_id>. Failed
credentials are C<rejected> without enumerating whether the account exists.

=head2 logout

Revokes a server-side session when a session id is present. Requires
C<command_id>. Command hashes include C<session_id> and C<user_id> only.

=head2 request_password_reset

Starts a password reset for an identifier. Requires C<command_id>.

=head2 reset_password

Completes a password reset with a token. Requires C<command_id>.
A reset to the same secret still revokes sessions.

=head2 change_password

Changes the password of an authenticated member. Requires C<command_id>.
Command hashes include C<user_id> only, never the current or new password.

=head2 request_email_change

Starts an email change for an authenticated member. Requires C<command_id>.
A request for the member's already-verified address does not issue a token.

=head2 confirm_email_change

Completes an email change with a token. Requires C<command_id>.

=head2 request_email_verification

Starts a registration verification resend for an identifier. Requires
C<command_id>.

=head2 verify_email

Completes registration verification with a token. Requires C<command_id>.

=head2 update_preferred_locale

Persists an authenticated member locale preference. Requires C<command_id>.

=head2 update_preferred_theme

Persists an authenticated member theme preference. Requires C<command_id>.

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
Guest cookie writes omit C<command_id>; authenticated preference writes
replay from C<command_log>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
