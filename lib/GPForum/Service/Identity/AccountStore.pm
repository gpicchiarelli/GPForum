# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::AccountStore;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Identity::Support;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $USER_AGGREGATE               => 'user';
const my $DAY_SECONDS                  => 86_400;
const my $HOUR_SECONDS                 => 3_600;
const my $PASSWORD_RESET_TOKEN_SECONDS => $HOUR_SECONDS;
const my $EMAIL_CHANGE_TOKEN_SECONDS   => $DAY_SECONDS;
const my $MINIMUM_PASSWORD_LENGTH      => 12;

__PACKAGE__->requires(
    qw(audit credential_store password schema session_store token_store));
has clock   => sub { return GPForum::Service::Clock->new; };
has support => sub { return GPForum::Service::Identity::Support->new; };

sub request_password_reset ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            return $self->_password_reset_in_txn($input);
        }
    );
}

sub reset_password ( $self, $input ) {
    my $password_error = $self->_password_error( $input->{password} );
    if ($password_error) {
        return { error => $password_error, ok => 0 };
    }

    return $self->schema->txn_do(
        sub {
            return $self->_reset_password_in_txn($input);
        }
    );
}

sub change_password ( $self, $input ) {
    my $password_error = $self->_password_error( $input->{new_password} );
    if ($password_error) {
        return { error => $password_error, ok => 0 };
    }
    my $user = $self->_find_user_by_id( $input->{user_id} );
    if ( !$user ) {
        return { error => 'not_found', ok => 0 };
    }
    my $verified = $self->credential_store->active_password_credential(
        $self->support->column( $user, 'id' ) );
    if ( !$self->_credential_matches( $verified, $input->{current_password} ) )
    {
        return { error => 'invalid_current_password', ok => 0 };
    }

    return $self->schema->txn_do(
        sub {
            return $self->_change_password_in_txn( $user, $input, $verified );
        }
    );
}

# An address the member already confirmed is skipped; one another member
# holds is refused before any token is issued.
sub request_email_change ( $self, $input ) {
    my $email       = $self->support->normalize_identifier( $input->{email} );
    my $email_error = $self->_email_error($email);
    if ($email_error) {
        return { error => $email_error, ok => 0 };
    }
    my $user = $self->_find_user_by_id( $input->{user_id} );
    if ( !$user ) {
        return { error => 'not_found', ok => 0 };
    }
    if ( $self->_email_already_confirmed( $user, $email ) ) {
        return {
            email_normalized => $email,
            ok               => 1,
            skipped          => 1,
        };
    }
    if ( $self->_email_taken( $email, $input->{user_id} ) ) {
        return { error => 'email_already_registered', ok => 0 };
    }

    return $self->schema->txn_do(
        sub {
            return $self->_request_email_change_in_txn( $user, $email, $input );
        }
    );
}

sub confirm_email_change ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            return $self->_confirm_email_change_in_txn($input);
        }
    );
}

# An unknown or deleted account is audited as not found and answered like a
# found one, so the answer does not tell who has an account.
sub _password_reset_in_txn ( $self, $input ) {
    my $user = $self->_find_login_user(
        $self->support->normalize_identifier( $input->{identifier} ) );
    if ( !$user || $self->_deleted_user($user) ) {
        return $self->_audit_not_found( 'identity.password_reset.requested',
            $input );
    }

    my $email = $self->support->column( $user, 'email_normalized' );
    my $token = $self->token_store->create_token(
        {
            email_normalized => $email,
            metadata         => {
                identifier_hash =>
                  $self->support->hash_value( $input->{identifier} ),
                request_address_hash =>
                  $self->support->hash_value( $input->{request_address} ),
            },
            token_type  => 'password_reset',
            ttl_seconds => $PASSWORD_RESET_TOKEN_SECONDS,
            user_id     => $self->support->column( $user, 'id' ),
        }
    );
    $self->_record_user_action(
        $user,
        'identity.password_reset.requested',
        {
            outcome              => 'issued',
            request_address_hash =>
              $self->support->hash_value( $input->{request_address} ),
            token_id => $token->{token_id},
        }
    );
    $self->_queue_issued_mail(
        $user,
        {
            kind  => 'password_reset',
            to    => $email,
            token => $token,
        }
    );

    return {
        email_normalized => $email,
        ok               => 1,
        token            => $token,
    };
}

sub _audit_not_found ( $self, $action, $input ) {
    $self->audit->record_action(
        {
            action   => $action,
            actor_id => undef,
            metadata => {
                identifier_hash =>
                  $self->support->hash_value( $input->{identifier} ),
                outcome              => 'not_found',
                request_address_hash =>
                  $self->support->hash_value( $input->{request_address} ),
            },
            target_id   => undef,
            target_type => 'identity',
        }
    );

    return { ok => 1, token => undef };
}

# A reset to the password the member already has keeps the credential; the
# sessions are revoked either way. The password is compared with the one the
# member has under the lock the rotation takes, so a change committed in the
# meantime is the one compared and then replaced.
sub _reset_password_in_txn ( $self, $input ) {
    my $token =
      $self->token_store->consume_token( 'password_reset', $input->{token} );
    if ( !$token->{ok} ) {
        return $token;
    }
    my $user = $self->_find_user_by_id( $token->{user_id} );
    if ( !$user ) {
        return { error => 'invalid_token', ok => 0 };
    }

    my $current = $self->_locked_password($user);
    my $now     = $self->clock->now_iso8601;
    my $same    = $self->_credential_matches( $current, $input->{password} );
    if ( !$same ) {
        $self->_store_password( $user, $input->{password}, $now );
    }
    $self->session_store->revoke_user_sessions(
        $self->support->column( $user, 'id' ), $now );
    $self->_record_user_action(
        $user,
        'identity.password_reset.completed',
        { token_id => $token->{token_id} }
    );

    return {
        ok      => 1,
        skipped => $same,
        user    => $user,
    };
}

# The current password was verified before this transaction, against the
# credential active then. A reset or another change that committed in
# between replaced that credential, and the change went on all the same: it
# rotated the new password away, so whoever knew the old one -- the reason
# for a reset -- set the last password and kept the account, and a change
# that waited for another one reported success with a password that was not
# stored. It goes on only while the credential it verified is the member's,
# locked until it commits; otherwise the current password it was given is no
# longer the current one.
sub _change_password_in_txn ( $self, $user, $input, $verified ) {
    my $current = $self->_locked_password($user);
    if (  !$current
        || $self->support->column( $current, 'id' ) ne
        $self->support->column( $verified, 'id' ) )
    {
        return { error => 'invalid_current_password', ok => 0 };
    }
    if ( $self->_credential_matches( $current, $input->{new_password} ) ) {
        return {
            ok      => 1,
            skipped => 1,
            user    => $user,
        };
    }

    $self->_store_password(
        $user,
        $input->{new_password},
        $self->clock->now_iso8601
    );

    # A password reset already did this. A change did not, so a user who
    # changed their password because they suspected a compromise left every
    # other device signed in. The session they are typing in is kept, when the
    # caller says which one it is.
    my $revoked = $self->session_store->revoke_user_sessions(
        $self->support->column( $user, 'id' ),
        $self->clock->now_iso8601,
        $input->{keep_session_id}
    );
    $self->_record_user_action( $user, 'identity.password.changed',
        { revoked_sessions => $revoked } );

    return { ok => 1, revoked_sessions => $revoked, user => $user };
}

# The new password becomes the active credential and the user row's hash.
sub _store_password ( $self, $user, $password, $now ) {
    my $secret_hash = $self->password->hash_password($password);
    $self->credential_store->rotate_password_credential(
        {
            secret_hash => $secret_hash,
            user_id     => $self->support->column( $user, 'id' ),
        }
    );
    $self->support->update_row(
        $user,
        {
            password_hash => $secret_hash,
            updated_at    => $now,
        }
    );

    return;
}

sub _request_email_change_in_txn ( $self, $user, $email, $input ) {
    my $token = $self->token_store->create_token(
        {
            email_normalized => $email,
            metadata         => {
                request_address_hash =>
                  $self->support->hash_value( $input->{request_address} ),
            },
            token_type  => 'email_change',
            ttl_seconds => $EMAIL_CHANGE_TOKEN_SECONDS,
            user_id     => $self->support->column( $user, 'id' ),
        }
    );
    $self->_record_user_action(
        $user,
        'identity.email_change.requested',
        {
            email_hash => $self->support->hash_value($email),
            token_id   => $token->{token_id},
        }
    );
    $self->_queue_issued_mail(
        $user,
        {
            kind  => 'email_change',
            to    => $email,
            token => $token,
        }
    );

    return {
        email_normalized => $email,
        ok               => 1,
        token            => $token,
    };
}

sub request_email_verification ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            return $self->_email_verification_in_txn($input);
        }
    );
}

sub confirm_email_verification ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            return $self->_confirm_email_verification_in_txn($input);
        }
    );
}

# The member is named by id when signed in, by username or address when not.
# Only a pending account is sent a verification; any other is audited as not
# found, like an unknown one.
sub _email_verification_in_txn ( $self, $input ) {
    my $user =
        $self->support->has_text( $input->{user_id} )
      ? $self->_find_user_by_id( $input->{user_id} )
      : $self->_find_login_user(
        $self->support->normalize_identifier( $input->{identifier} ) );
    if ( !$user || $self->_deleted_user($user) || !$self->_pending_user($user) )
    {
        return $self->_audit_not_found( 'identity.email_verification.requested',
            $input );
    }

    my $email = $self->support->column( $user, 'email_normalized' );
    my $token = $self->token_store->create_token(
        {
            email_normalized => $email,
            metadata         => {
                request_address_hash =>
                  $self->support->hash_value( $input->{request_address} ),
            },
            token_type  => 'email_verification',
            ttl_seconds => $EMAIL_CHANGE_TOKEN_SECONDS,
            user_id     => $self->support->column( $user, 'id' ),
        }
    );
    $self->_record_user_action(
        $user,
        'identity.email_verification.requested',
        {
            outcome              => 'issued',
            request_address_hash =>
              $self->support->hash_value( $input->{request_address} ),
            token_id => $token->{token_id},
        }
    );
    $self->_queue_issued_mail(
        $user,
        {
            kind  => 'email_verification',
            to    => $email,
            token => $token,
        }
    );

    return {
        email_normalized => $email,
        ok               => 1,
        token            => $token,
    };
}

sub _confirm_email_verification_in_txn ( $self, $input ) {
    my $token =
      $self->token_store->consume_token( 'email_verification',
        $input->{token} );
    if ( !$token->{ok} ) {
        return $token;
    }
    my $user = $self->_find_user_by_id( $token->{user_id} );
    if ( !$user ) {
        return { error => 'invalid_token', ok => 0 };
    }
    if ( $self->_already_verified($user) ) {
        return {
            ok      => 1,
            skipped => 1,
            user    => $user,
        };
    }

    my $now = $self->clock->now_iso8601;
    $self->support->update_row(
        $user,
        {
            email_verified_at => $now,
            status            => 'active',
            updated_at        => $now,
        }
    );
    $self->_record_user_action(
        $user,
        'identity.email_verification.confirmed',
        { token_id => $token->{token_id} }
    );

    return { ok => 1, user => $user };
}

sub _already_verified ( $self, $user ) {
    if ( $self->_pending_user($user) ) {
        return 0;
    }
    if ( !defined $self->support->column( $user, 'email_verified_at' ) ) {
        return 0;
    }

    return 1;
}

sub _pending_user ( $self, $user ) {
    my $status = $self->support->column( $user, 'status' ) || q{};
    return $status eq 'pending' ? 1 : 0;
}

sub _confirm_email_change_in_txn ( $self, $input ) {
    my $token =
      $self->token_store->consume_token( 'email_change', $input->{token} );
    if ( !$token->{ok} ) {
        return $token;
    }
    my $email = $token->{email_normalized};
    if ( !$email ) {
        return { error => 'invalid_token', ok => 0 };
    }
    if ( $self->_email_taken( $email, $token->{user_id} ) ) {
        return { error => 'email_already_registered', ok => 0 };
    }
    my $user = $self->_find_user_by_id( $token->{user_id} );
    if ( !$user ) {
        return { error => 'invalid_token', ok => 0 };
    }
    if ( $self->_email_already_confirmed( $user, $email ) ) {
        return {
            ok      => 1,
            skipped => 1,
            user    => $user,
        };
    }

    return $self->_store_confirmed_email( $user, $email, $token );
}

# The address is looked up once more inside the savepoint, and a member who
# takes it after that is refused by the unique constraint: either way the
# address is taken. Any other failure, the audit's included, is rethrown.
sub _store_confirmed_email ( $self, $user, $email, $token ) {
    my $user_id = $self->support->column( $user, 'id' );
    my ( $stored, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            if ( $self->_email_taken( $email, $user_id ) ) {
                GPForum::Infrastructure::UniqueConflict->throw(
                    'users_email_normalized_key');
            }
            my $now = $self->clock->now_iso8601;
            $self->support->update_row(
                $user,
                {
                    email_normalized  => $email,
                    email_verified_at => $now,
                    updated_at        => $now,
                }
            );
            $self->_record_user_action(
                $user,
                'identity.email_change.confirmed',
                {
                    email_hash => $self->support->hash_value($email),
                    token_id   => $token->{token_id},
                }
            );

            return { ok => 1, user => $user };
        },
    );
    if ($stored) {
        return $stored;
    }

    if ( !GPForum::X::Conflict->caught($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return { error => 'email_already_registered', ok => 0 };
}

sub _email_already_confirmed ( $self, $user, $email ) {
    if ( !$self->_already_verified($user) ) {
        return 0;
    }

    my $held = $self->support->column( $user, 'email_normalized' ) || q{};
    return $held eq $email ? 1 : 0;
}

sub _record_user_action ( $self, $user, $action, $metadata ) {
    my $user_id = $self->support->column( $user, 'id' );
    $self->audit->record_action(
        {
            action      => $action,
            actor_id    => $user_id,
            metadata    => $metadata,
            target_id   => $user_id,
            target_type => $USER_AGGREGATE,
        }
    );

    return;
}

# Mail is queued only with an address to send to and a raw token to send.
sub _queue_issued_mail ( $self, $user, $mail ) {
    my $token = $mail->{token} || {};
    if (   !$self->support->has_text( $mail->{to} )
        || !$self->support->has_text( $token->{raw_token} ) )
    {
        return;
    }

    $self->audit->record_mail(
        {
            kind     => $mail->{kind},
            to       => $mail->{to},
            token    => $token->{raw_token},
            token_id => $token->{token_id},
            user_id  => $self->support->column( $user, 'id' ),
        }
    );

    return;
}

sub _credential_matches ( $self, $credential, $password ) {
    if ( !$credential ) {
        return 0;
    }

    return $self->password->verify_password( $password,
        $self->support->column( $credential, 'secret_hash' ) ) ? 1 : 0;
}

# The member's active password, locked until the transaction ends; undef
# when there is none. The partial unique index keeps it to one.
sub _locked_password ( $self, $user ) {
    my ($credential) =
      $self->credential_store->lock_active_password_credentials(
        $self->support->column( $user, 'id' ) );

    return $credential;
}

sub _find_user_by_id ( $self, $user_id ) {
    if ( !$self->support->has_text($user_id) ) {
        return undef;
    }

    return $self->schema->resultset('User')->find( { id => $user_id } );
}

# An identifier with an @ is an address; any other is a username.
sub _find_login_user ( $self, $identifier ) {
    if ( !length $identifier ) {
        return undef;
    }

    my $column = $identifier =~ /[@]/msx ? 'email_normalized' : 'username';
    return $self->schema->resultset('User')->find( { $column => $identifier } );
}

sub _deleted_user ( $self, $user ) {
    my $status = $self->support->column( $user, 'status' ) || q{};
    return $status eq 'deleted' ? 1 : 0;
}

# Held by another member: the member's own address is not taken.
sub _email_taken ( $self, $email, $current_user_id ) {
    my $existing =
      $self->schema->resultset('User')->find( { email_normalized => $email } );
    if ( !$existing ) {
        return 0;
    }

    my $existing_id = $self->support->column( $existing, 'id' );
    if (   $self->support->has_text($existing_id)
        && $self->support->has_text($current_user_id)
        && $existing_id eq $current_user_id )
    {
        return 0;
    }

    return 1;
}

sub _email_error ( $, $email ) {
    if ( !length $email ) {
        return 'email_required';
    }
    if ( $email !~
        /\A [[:alnum:]._%+-]+ [@] [[:alnum:].-]+ [.] [[:alpha:]]{2,} \z/imsx )
    {
        return 'email_invalid';
    }

    return undef;
}

sub _password_error ( $, $password ) {
    if ( !defined $password || !length $password ) {
        return 'password_required';
    }
    if ( length $password < $MINIMUM_PASSWORD_LENGTH ) {
        return 'password_too_short';
    }

    return undef;
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::AccountStore - Password and email account writes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = $store->change_password(
        {
            current_password => $current,
            new_password     => $new,
            user_id          => $user_id,
        }
    );

=head1 DESCRIPTION

Owns password reset, password change, and email change persistence. The
identity store facade delegates these commands so HTTP and workflow callers
keep a stable API. Credential, session, token, and audit stores keep their
row-level ownership. Issued tokens enqueue C<identity.mail.requested> on
the outbox in the same transaction; EventLog payloads keep C<kind> and
C<token_id> only.

=head1 SUBROUTINES/METHODS

=head2 request_password_reset

Issues a reset token without revealing whether the identifier exists.

=head2 reset_password

Consumes a reset token and rotates the password credential. A reset to
the same secret still consumes the token and revokes sessions, but does
not rotate the credential. The member's active credential is locked
before it is compared, so a reset that waited for a concurrent change
replaces the password that change set.

=head2 change_password

Rotates the password for an authenticated member. A second write of the
same secret returns C<skipped> and does not rotate the credential. The
current password is verified before the transaction, against the active
credential; the transaction locks the active credential and answers
C<invalid_current_password> when it is no longer the one verified, because
a reset or another change replaced it in between.

=head2 request_email_change

Issues an email-change token when the address is available. A request
for the member's already-verified address returns C<skipped> and does
not issue a token.

=head2 confirm_email_change

Consumes an email-change token and updates the user row. A second
confirmation of the same already-verified address returns C<skipped>
and does not restamp C<email_verified_at>. A unique race on
C<email_normalized> returns C<email_already_registered> and does not
restamp the user.

=head2 request_email_verification

Issues a registration verification token for a pending user without
revealing whether the identifier exists.

=head2 confirm_email_verification

Consumes a verification token, marks the email verified, and activates
the user. A second confirmation for an already-active verified user
returns C<skipped> and does not restamp C<email_verified_at>.

=head1 DIAGNOSTICS

Missing users and invalid tokens return C<not_found> or C<invalid_token>.
Weak passwords return C<password_too_short>. Duplicate emails return
C<email_already_registered>. Password reset for unknown identifiers still
returns C<ok> without a token.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a schema with User resultset plus credential, session, token, and
audit collaborators supplied by the identity store facade.

=head1 DEPENDENCIES

Uses L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::X::Conflict> and
L<GPForum::Service::Identity::Support>.

Extends L<GPForum::Base>: built without C<audit>, C<credential_store>,
C<password>, C<schema>, C<session_store> or C<token_store> it throws
L<GPForum::X::Argument>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Password reset remains non-enumerative: unknown identifiers succeed without
issuing a token.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
