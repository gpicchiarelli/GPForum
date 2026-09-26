# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::AccountStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Identity::Support;

our $VERSION = '0.001';

const my $USER_AGGREGATE               => 'user';
const my $DAY_SECONDS                  => 86_400;
const my $HOUR_SECONDS                 => 3_600;
const my $PASSWORD_RESET_TOKEN_SECONDS => $HOUR_SECONDS;
const my $EMAIL_CHANGE_TOKEN_SECONDS   => $DAY_SECONDS;
const my $MINIMUM_PASSWORD_LENGTH      => 12;

has audit            => undef;
has clock            => sub { return GPForum::Service::Clock->new; };
has credential_store => undef;
has password         => undef;
has schema           => undef;
has session_store    => undef;
has support     => sub { return GPForum::Service::Identity::Support->new; };
has token_store => undef;

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
    my $checked = $self->_change_password_precheck($input);
    if ( !$checked->{ok} ) {
        return $checked;
    }

    return $self->schema->txn_do(
        sub {
            return $self->_change_password_in_txn( $checked->{user}, $input );
        }
    );
}

sub request_email_change ( $self, $input ) {
    my $checked = $self->_email_change_precheck($input);
    if ( !$checked->{ok} ) {
        return $checked;
    }
    if ( $checked->{skipped} ) {
        return $self->_skipped_email_request($checked);
    }

    $checked->{input} = $input;

    return $self->schema->txn_do(
        sub {
            return $self->_request_email_change_in_txn($checked);
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

sub _password_reset_in_txn ( $self, $input ) {
    my $user = $self->_find_login_user(
        $self->support->normalize_identifier( $input->{identifier} ) );
    if ( !$user || $self->_deleted_user($user) ) {
        return $self->_password_reset_missing($input);
    }

    return $self->_issue_password_reset( $user, $input );
}

sub _password_reset_missing ( $self, $input ) {
    $self->audit->record_action(
        {
            action   => 'identity.password_reset.requested',
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

sub _issue_password_reset ( $self, $user, $input ) {
    my $token = $self->token_store->create_token(
        {
            email_normalized =>
              $self->support->column( $user, 'email_normalized' ),
            metadata => {
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
            to    => $self->support->column( $user, 'email_normalized' ),
            token => $token,
        }
    );

    return {
        email_normalized => $self->support->column( $user, 'email_normalized' ),
        ok               => 1,
        token            => $token,
    };
}

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

    return $self->_apply_reset_password( $user, $input->{password}, $token );
}

sub _apply_reset_password ( $self, $user, $password, $token ) {
    my $now     = $self->clock->now_iso8601;
    my $user_id = $self->support->column( $user, 'id' );
    my $same    = $self->_password_matches( $user, $password );
    if ( !$same ) {
        $self->_rotate_reset_secret( $user, $password, $now );
    }
    $self->session_store->revoke_user_sessions( $user_id, $now );
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

sub _rotate_reset_secret ( $self, $user, $password, $now ) {
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

sub _change_password_precheck ( $self, $input ) {
    my $password_error = $self->_password_error( $input->{new_password} );
    if ($password_error) {
        return { error => $password_error, ok => 0 };
    }

    return $self->_change_password_user($input);
}

sub _change_password_user ( $self, $input ) {
    my $user = $self->_find_user_by_id( $input->{user_id} );
    if ( !$user ) {
        return { error => 'not_found', ok => 0 };
    }
    if ( !$self->_password_matches( $user, $input->{current_password} ) ) {
        return { error => 'invalid_current_password', ok => 0 };
    }

    return { ok => 1, user => $user };
}

sub _change_password_in_txn ( $self, $user, $input ) {
    if ( $self->_password_matches( $user, $input->{new_password} ) ) {
        return {
            ok      => 1,
            skipped => 1,
            user    => $user,
        };
    }

    return $self->_rotate_password( $user, $input );
}

sub _rotate_password ( $self, $user, $input ) {
    my $secret_hash = $self->password->hash_password( $input->{new_password} );
    my $user_id     = $self->support->column( $user, 'id' );
    $self->credential_store->rotate_password_credential(
        {
            secret_hash => $secret_hash,
            user_id     => $user_id,
        }
    );
    $self->support->update_row(
        $user,
        {
            password_hash => $secret_hash,
            updated_at    => $self->clock->now_iso8601,
        }
    );

    # A password reset already did this. A change did not, so a user who
    # changed their password because they suspected a compromise left every
    # other device signed in. The session they are typing in is kept, when the
    # caller says which one it is.
    my $revoked = $self->session_store->revoke_user_sessions(
        $user_id,
        $self->clock->now_iso8601,
        $input->{keep_session_id}
    );
    $self->_record_user_action( $user, 'identity.password.changed',
        { revoked_sessions => $revoked } );

    return { ok => 1, revoked_sessions => $revoked, user => $user };
}

sub _email_change_precheck ( $self, $input ) {
    my $email       = $self->support->normalize_identifier( $input->{email} );
    my $email_error = $self->_email_error($email);
    if ($email_error) {
        return { error => $email_error, ok => 0 };
    }

    return $self->_email_change_user( $input, $email );
}

sub _email_change_user ( $self, $input, $email ) {
    my $user = $self->_find_user_by_id( $input->{user_id} );
    if ( !$user ) {
        return { error => 'not_found', ok => 0 };
    }
    if ( $self->_email_already_confirmed( $user, $email ) ) {
        return {
            email   => $email,
            ok      => 1,
            skipped => 1,
            user    => $user,
        };
    }
    if ( $self->_email_taken( $email, $input->{user_id} ) ) {
        return { error => 'email_already_registered', ok => 0 };
    }

    return { email => $email, ok => 1, user => $user };
}

sub _skipped_email_request ( $self, $checked ) {
    return {
        email_normalized => $checked->{email},
        ok               => 1,
        skipped          => 1,
    };
}

sub _request_email_change_in_txn ( $self, $checked ) {
    if ( $checked->{skipped} ) {
        return $self->_skipped_email_request($checked);
    }

    my $email   = $checked->{email};
    my $input   = $checked->{input};
    my $user    = $checked->{user};
    my $user_id = $self->support->column( $user, 'id' );
    my $token   = $self->token_store->create_token(
        {
            email_normalized => $email,
            metadata         => {
                request_address_hash =>
                  $self->support->hash_value( $input->{request_address} ),
            },
            token_type  => 'email_change',
            ttl_seconds => $EMAIL_CHANGE_TOKEN_SECONDS,
            user_id     => $user_id,
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

sub _email_verification_in_txn ( $self, $input ) {
    my $user = $self->_find_verification_user($input);
    if ( !$user || $self->_deleted_user($user) ) {
        return $self->_email_verification_missing($input);
    }
    if ( !$self->_pending_user($user) ) {
        return $self->_email_verification_missing($input);
    }

    return $self->_issue_email_verification( $user, $input );
}

sub _find_verification_user ( $self, $input ) {
    if ( $self->support->has_text( $input->{user_id} ) ) {
        return $self->_find_user_by_id( $input->{user_id} );
    }

    return $self->_find_login_user(
        $self->support->normalize_identifier( $input->{identifier} ) );
}

sub _email_verification_missing ( $self, $input ) {
    $self->audit->record_action(
        {
            action   => 'identity.email_verification.requested',
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

sub _issue_email_verification ( $self, $user, $input ) {
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

    return $self->_apply_email_verification($token);
}

sub _apply_email_verification ( $self, $token ) {
    my $user = $self->_find_user_by_id( $token->{user_id} );
    if ( !$user ) {
        return { error => 'invalid_token', ok => 0 };
    }

    return $self->_store_email_verification( $user, $token );
}

sub _store_email_verification ( $self, $user, $token ) {
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

    return $self->_apply_confirmed_email($token);
}

sub _apply_confirmed_email ( $self, $token ) {
    my $email = $token->{email_normalized};
    if ( !$email ) {
        return { error => 'invalid_token', ok => 0 };
    }
    if ( $self->_email_taken( $email, $token->{user_id} ) ) {
        return { error => 'email_already_registered', ok => 0 };
    }

    return $self->_confirmed_email_user( $token, $email );
}

sub _confirmed_email_user ( $self, $token, $email ) {
    my $user = $self->_find_user_by_id( $token->{user_id} );
    if ( !$user ) {
        return { error => 'invalid_token', ok => 0 };
    }

    return $self->_store_confirmed_email( $user, $email, $token );
}

sub _store_confirmed_email ( $self, $user, $email, $token ) {
    if ( $self->_email_already_confirmed( $user, $email ) ) {
        return {
            ok      => 1,
            skipped => 1,
            user    => $user,
        };
    }

    return $self->_persist_confirmed_email(
        {
            email => $email,
            token => $token,
            user  => $user,
        }
    );
}

sub _persist_confirmed_email ( $self, $job ) {
    my ( $stored, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_write_confirmed_email($job); },
      );
    if ($stored) {
        return $stored;
    }

    return $self->_email_after_conflict($error);
}

sub _write_confirmed_email ( $self, $job ) {
    $self->_guard_email_unique($job);
    return $self->_commit_confirmed_email($job);
}

sub _guard_email_unique ( $self, $job ) {
    my $user_id = $self->support->column( $job->{user}, 'id' );
    if ( $self->_email_taken( $job->{email}, $user_id ) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'users_email_normalized_key');
    }

    return;
}

sub _commit_confirmed_email ( $self, $job ) {
    my $now = $self->clock->now_iso8601;
    $self->support->update_row(
        $job->{user},
        {
            email_normalized  => $job->{email},
            email_verified_at => $now,
            updated_at        => $now,
        }
    );
    $self->_record_user_action(
        $job->{user},
        'identity.email_change.confirmed',
        {
            email_hash => $self->support->hash_value( $job->{email} ),
            token_id   => $job->{token}{token_id},
        }
    );

    return { ok => 1, user => $job->{user} };
}

sub _email_after_conflict ( $, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
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

sub _queue_issued_mail ( $self, $user, $mail ) {
    if ( !$self->_mailable($mail) ) {
        return;
    }

    $self->audit->record_mail( $self->_mail_record( $user, $mail ) );

    return;
}

sub _mailable ( $self, $mail ) {
    my $token = $mail->{token} || {};
    if ( !$self->support->has_text( $mail->{to} ) ) {
        return 0;
    }

    return $self->support->has_text( $token->{raw_token} );
}

sub _mail_record ( $self, $user, $mail ) {
    my $token = $mail->{token};

    return {
        kind     => $mail->{kind},
        to       => $mail->{to},
        token    => $token->{raw_token},
        token_id => $token->{token_id},
        user_id  => $self->support->column( $user, 'id' ),
    };
}

sub _password_matches ( $self, $user, $password ) {
    my $credential = $self->credential_store->active_password_credential(
        $self->support->column( $user, 'id' ) );
    if ( !$credential ) {
        return 0;
    }

    return $self->password->verify_password( $password,
        $self->support->column( $credential, 'secret_hash' ) );
}

sub _find_user_by_id ( $self, $user_id ) {
    if ( !$self->support->has_text($user_id) ) {
        my $undefined;
        return $undefined;
    }

    return $self->schema->resultset('User')->find( { id => $user_id } );
}

sub _find_login_user ( $self, $identifier ) {
    if ( !length $identifier ) {
        my $undefined;
        return $undefined;
    }

    return $self->_lookup_login_user($identifier);
}

sub _lookup_login_user ( $self, $identifier ) {
    my $users = $self->schema->resultset('User');
    if ( $identifier =~ /[@]/msx ) {
        return $users->find( { email_normalized => $identifier } );
    }

    return $users->find( { username => $identifier } );
}

sub _deleted_user ( $self, $user ) {
    my $status = $self->support->column( $user, 'status' ) || q{};
    return $status eq 'deleted' ? 1 : 0;
}

sub _email_taken ( $self, $email, $current_user_id ) {
    my $existing =
      $self->schema->resultset('User')->find( { email_normalized => $email } );
    if ( !$existing ) {
        return 0;
    }

    return $self->_email_belongs_to_other( $existing, $current_user_id );
}

sub _email_belongs_to_other ( $self, $existing, $current_user_id ) {
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

    my $undefined;
    return $undefined;
}

sub _password_error ( $, $password ) {
    if ( !defined $password || !length $password ) {
        return 'password_required';
    }
    if ( length $password < $MINIMUM_PASSWORD_LENGTH ) {
        return 'password_too_short';
    }

    my $undefined;
    return $undefined;
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
not rotate the credential.

=head2 change_password

Rotates the password for an authenticated member. A second write of the
same secret returns C<skipped> and does not rotate the credential.

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

Uses L<GPForum::Infrastructure::UniqueConflict> and
L<GPForum::Service::Identity::Support>.

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
