# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::Workflow;

use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Service::Identity::Support;

our $VERSION = '0.001';

has command_idempotency => undef;    # optional: writes run unlogged without one
has logger              => undef;    # optional: errors are dropped without one
__PACKAGE__->requires(qw(registration store));
has support => sub { return GPForum::Service::Identity::Support->new; };

sub register ( $self, $input ) {
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

# A login is never answered from the command log. It was: a replay keyed on
# the command id and the identifier handed the stored session -- bearer
# token included -- to whoever sent them, whatever the password, and the
# token sat in command_log in plain. Every attempt now checks the password;
# a retried login whose response was lost opens another session, which is
# harmless.
sub login ( $self, $input ) {
    my $invalid = $self->_missing_fields( $input, [qw(identifier password)] );
    if ($invalid) {
        return $invalid;
    }

    my $tried = $self->_try_store(
        sub { return $self->store->authenticate_login($input); } );
    if ( $tried->{failed} ) {
        return _failed_result();
    }
    my $stored = $tried->{value};
    if ( !$stored || !$stored->{ok} ) {
        my $unverified =
          $stored && ( $stored->{error} || q{} ) eq q{unverified};
        my $error =
          $unverified ? q{unverified} : q{login request could not be accepted};
        return _result( error => $error, status => q{rejected} );
    }

    return _result(
        status => 'ok',
        stored => {
            preferred_locale =>
              $self->_login_preference( $stored, 'preferred_locale' ),
            preferred_theme =>
              $self->_login_preference( $stored, 'preferred_theme' ),
            preferred_timezone =>
              $self->_login_preference( $stored, 'preferred_timezone' ),
            session_id => $stored->{session_id},

            # The per-session bearer token. It reaches the cookie and nowhere
            # else: the database keeps only its SHA-256, which is what
            # validate_session compares on every request.
            session_token => $stored->{session_token},
            user_id       => $stored->{user_id},
        },
    );
}

# Signing out of no session is already done.
sub logout ( $self, $input ) {
    my $invalid = $self->_missing_fields( $input, ['command_id'] );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_write(
        {
            actor_id     => $input->{user_id},
            command_id   => $input->{command_id},
            command_type => 'identity.logout',
            request      => {
                session_id => _trim( $input->{session_id} ),
                user_id    => _trim( $input->{user_id} ),
            },
            run => sub {
                if ( !length _trim( $input->{session_id} ) ) {
                    return _result(
                        status => 'ok',
                        stored => { skipped => 1 },
                    );
                }
                return $self->_public_consume_result(
                    sub { return $self->store->revoke_session($input); } );
            },
        }
    );
}

sub request_password_reset ( $self, $input ) {
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

sub reset_password ( $self, $input ) {
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

sub change_password ( $self, $input ) {
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

sub request_email_change ( $self, $input ) {
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

sub request_email_verification ( $self, $input ) {
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

sub verify_email ( $self, $input ) {
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

sub confirm_email_change ( $self, $input ) {
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

sub update_preferred_locale ( $self, $input ) {
    return $self->_preference_write(
        {
            command_type => 'identity.locale_change',
            field        => 'preferred_locale',
            input        => $input,
            required     => [qw(command_id user_id preferred_locale)],
            run          => sub {
                return $self->store->update_preferred_locale($input);
            },
        }
    );
}

sub update_preferred_theme ( $self, $input ) {
    return $self->_preference_write(
        {
            command_type => 'identity.theme_change',
            field        => 'preferred_theme',
            input        => $input,
            required     => [qw(command_id user_id preferred_theme)],
            run          => sub {
                return $self->store->update_preferred_theme($input);
            },
        }
    );
}

# An empty zone is a choice (the forum's default), so only the command and
# the member are required.
sub update_preferred_timezone ( $self, $input ) {
    return $self->_preference_write(
        {
            command_type => 'identity.timezone_change',
            field        => 'preferred_timezone',
            input        => $input,
            required     => [qw(command_id user_id)],
            run          => sub {
                return $self->store->update_preferred_timezone($input);
            },
        }
    );
}

# A preference write answers with the value stored and nothing else.
sub _preference_write ( $self, $job ) {
    my $input   = $job->{input};
    my $field   = $job->{field};
    my $invalid = $self->_missing_fields( $input, $job->{required} );
    if ($invalid) {
        return $invalid;
    }

    return $self->_commanded_write(
        {
            actor_id     => $input->{user_id},
            command_id   => $input->{command_id},
            command_type => $job->{command_type},
            request      => {
                $field  => _trim( $input->{$field} ),
                user_id => $input->{user_id},
            },
            run => sub {
                my $result = $self->_store_write( $job->{run} );
                if ( !$result->{ok} ) {
                    return $result;
                }
                return _result(
                    status => 'ok',
                    stored => {
                        ok     => 1,
                        $field => $result->{stored}{$field},
                    },
                );
            },
        }
    );
}

# The registration is prepared, then stored. A stored account is sent its
# verification mail; a mail that cannot be queued does not undo the account.
sub _register_account ( $self, $input ) {
    my $tried =
      $self->_try_store( sub { return $self->registration->prepare($input); } );
    my $prepared = $tried->{value};
    if ( $tried->{failed} || !$prepared ) {
        return _failed_result();
    }
    if ( !$prepared->{ok} ) {
        return _result(
            errors => $prepared->{errors},
            status => 'invalid',
            stored => { values => $prepared->{values} },
        );
    }

    my $stored = $self->_try_store(
        sub {
            return $self->store->create_registration(
                $prepared->{registration} );
        }
    );
    if ( $stored->{failed} ) {
        return _failed_result();
    }
    my $created = $stored->{value};
    if ( !$created || !$created->{ok} ) {
        return _result(
            errors => {
                registration => 'registration request could not be accepted',
            },
            status => 'invalid',
            stored => { values => $prepared->{values} },
        );
    }

    $self->_try_store(
        sub {
            return $self->store->request_email_verification(
                { user_id => $self->support->column( $created->{user}, 'id' ) }
            );
        }
    );

    return _result(
        status => 'ok',
        stored => {
            registration => $prepared->{registration},
            user         => $created->{user},
            values       => $prepared->{values},
        },
    );
}

sub _token_consume_write ( $self, $job ) {
    my $input   = $job->{input};
    my $invalid = $self->_missing_fields( $input,
        [ 'command_id', 'token', @{ $job->{extra_fields} || [] } ] );
    if ($invalid) {
        return $invalid;
    }

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

sub _public_consume_result ( $self, $code ) {
    my $result = $self->_store_write($code);
    if ( !$result->{ok} ) {
        return $result;
    }

    return _result(
        status => 'ok',
        stored => { ok => 1 },
    );
}

sub _login_preference ( $self, $stored, $name ) {
    if ( $self->support->has_text( $stored->{$name} ) ) {
        return $stored->{$name};
    }

    return $self->support->column( $stored->{user}, $name );
}

# Without a command log a write just runs. With one, a command id seen
# before answers what it answered then, a new one runs and is recorded, and
# one reused for another request is a conflict.
sub _commanded_write ( $self, $job ) {
    if ( !$self->command_idempotency ) {
        return $job->{run}->();
    }

    my $guarded;
    try {
        $guarded = $self->command_idempotency->run(
            {
                actor_id     => $job->{actor_id},
                command_id   => _trim( $job->{command_id} ),
                command_type => $job->{command_type},
                request      => $job->{request} || {},
            },
            sub { return $job->{run}->(); },
            sub ($result) { return _command_log_response($result); },
        );
    }
    catch ($error) {
        $self->_log_error("identity command log failed: $error");
        return _failed_result();
    };
    if ( $guarded->{replayed} ) {
        return $guarded->{response};
    }
    if ( $guarded->{recorded} ) {
        return $guarded->{result};
    }
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

# A write that issues a token answers without its raw value or its hash.
sub _commanded_token_write ( $self, $job ) {
    return $self->_commanded_write(
        {
            actor_id     => $job->{actor_id},
            command_id   => $job->{command_id},
            command_type => $job->{command_type},
            request      => $job->{request},
            run          => sub {
                my $result = $self->_store_write( $job->{run} );
                if ( !$result->{ok} ) {
                    return $result;
                }
                return _public_write_result($result);
            },
        }
    );
}

# What the command log keeps of a result: no token, the user row reduced to
# its id, and nothing that is not plain data.
sub _command_log_response ($result) {
    my $public = _public_write_result($result);
    if ( ref $public ne 'HASH' ) {
        return {};
    }

    my %response = %{$public};
    if ( ref $response{stored} eq 'HASH' ) {
        my %stored = %{ $response{stored} };
        my $user   = delete $stored{user};
        if ( !exists $stored{user_id} && defined $user ) {
            $stored{user_id} =
              GPForum::Service::Identity::Support->new->column( $user, 'id' );
        }
        $response{stored} = _jsonable_value( \%stored );
    }

    return \%response;
}

# Hashes and arrays are copied; an object, or any other reference, is
# dropped.
sub _jsonable_value ($value) {
    if ( ref $value eq 'HASH' ) {
        return { map { $_ => _jsonable_value( $value->{$_} ) } keys %{$value} };
    }
    if ( ref $value eq 'ARRAY' ) {
        return [ map { _jsonable_value($_) } @{$value} ];
    }
    if ( ref $value ) {
        return undef;
    }

    return $value;
}

sub _public_write_result ($result) {
    my $stored = $result->{stored} || {};
    my $token  = $stored->{token};
    if ( ref $token eq 'HASH' ) {
        delete $token->{raw_token};
        delete $token->{token_hash};
    }

    return $result;
}

sub _store_write ( $self, $code ) {
    my $tried = $self->_try_store($code);
    my $value = $tried->{value};
    if ( $tried->{failed} || !$value ) {
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

sub _missing_fields ( $, $input, $names ) {
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

    return undef;
}

sub _try_store ( $self, $code ) {
    my $value;
    try {
        $value = $code->();
    }
    catch ($error) {
        $self->_log_error("identity write failed: $error");
        return { failed => 1 };
    };

    return { value => $value };
}

sub _failed_result {
    return _result(
        error  => 'identity store failed',
        status => 'failed',
    );
}

sub _result (%input) {
    return {
        error  => $input{error},
        errors => $input{errors},
        ok     => ( $input{status} || q{} ) eq 'ok' ? 1 : 0,
        status => $input{status} || 'failed',
        stored => $input{stored},
    };
}

sub _trim ($value) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _log_error ( $self, $message ) {
    if ( !$self->logger ) {
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

=head2 update_preferred_timezone

Persists a member's time zone, or the forum's default for an empty one.
Requires C<command_id>.

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

Uses L<GPForum::Base>.

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
