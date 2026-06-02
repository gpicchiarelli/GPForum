package GPForum::Service::Identity::Store;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use Mojo::Base -base;
use POSIX qw(strftime);

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Clock;
use GPForum::Service::Id;
use GPForum::Service::Password;
use GPForum::Service::SessionToken;

our $VERSION = '0.001';

const my $USER_AGGREGATE               => 'user';
const my $SCHEMA_VERSION               => 1;
const my $SESSION_DAYS                 => 30;
const my $DAY_SECONDS                  => 86_400;
const my $HOUR_SECONDS                 => 3_600;
const my $PASSWORD_RESET_TOKEN_SECONDS => $HOUR_SECONDS;
const my $EMAIL_CHANGE_TOKEN_SECONDS   => $DAY_SECONDS;
const my $MINIMUM_PASSWORD_LENGTH      => 12;

has schema     => undef;
has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has password   => sub { return GPForum::Service::Password->new; };
has recorder   => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has session_tokens  => sub { return GPForum::Service::SessionToken->new; };
has session_seconds => sub { return $SESSION_DAYS * $DAY_SECONDS; };

sub create_registration {
    my ( $self, $registration ) = @_;

    my $errors = $self->_duplicate_errors( $registration->{user} );

    return { ok => 0, errors => $errors }
      if keys %{$errors};

    my $result = $self->schema->txn_do(
        sub {
            return $self->_insert_registration($registration);
        }
    );

    return { ok => 1, user => $result->{user} };
}

sub _duplicate_errors {
    my ( $self, $user ) = @_;

    my %errors;

    if ( $self->schema->resultset('User')
        ->find( { username => $user->{username} } ) )
    {
        $errors{username} = 'username is already registered';
    }

    if ( $self->schema->resultset('User')
        ->find( { email_normalized => $user->{email_normalized} } ) )
    {
        $errors{email} = 'email is already registered';
    }

    return \%errors;
}

sub _insert_registration {
    my ( $self, $registration ) = @_;

    my $user       = $registration->{user};
    my $credential = $registration->{credential};
    $user->{password_hash} ||= $credential->{secret_hash};

    my $created_user = $self->schema->resultset('User')->create($user);

    $self->schema->resultset('Credential')->create(
        {
            id          => $self->id_service->uuid,
            user_id     => $user->{id},
            type        => $credential->{type},
            secret_hash => $credential->{secret_hash},
        }
    );

    my $correlation_id = $self->id_service->uuid;

    $self->_record_event( $user, $correlation_id );
    $self->_record_audit( $user, $correlation_id );

    return { user => $created_user };
}

sub authenticate_login {
    my ( $self, $input ) = @_;

    my $identifier = _normalize_identifier( $input->{identifier} );
    my $password   = $input->{password};
    my $user       = $self->_find_login_user($identifier);

    return _invalid_login() if !$user;
    return _invalid_login()
      if ( _column( $user, 'status' ) || q{} ) eq 'deleted';

    my $credential =
      $self->_active_password_credential( _column( $user, 'id' ) );
    return _invalid_login() if !$credential;
    return _invalid_login()
      if !$self->password->verify_password( $password,
        _column( $credential, 'secret_hash' ) );

    my $session = $self->_create_session( $user, $input );

    return {
        ok         => 1,
        session    => $session->{session},
        session_id => _column( $session->{session}, 'session_id' ),
        user       => $user,
        user_id    => _column( $user, 'id' ),
    };
}

sub request_password_reset {
    my ( $self, $input ) = @_;

    my $identifier = _normalize_identifier( $input->{identifier} );
    my $user       = $self->_find_login_user($identifier);

    return $self->schema->txn_do(
        sub {
            if ( !$user || ( _column( $user, 'status' ) || q{} ) eq 'deleted' )
            {
                $self->_record_identity_audit(
                    action      => 'identity.password_reset.requested',
                    actor_id    => undef,
                    target_type => 'identity',
                    target_id   => undef,
                    metadata    => {
                        identifier_hash => _hash_value( $input->{identifier} ),
                        request_address_hash =>
                          _hash_value( $input->{request_address} ),
                        outcome => 'not_found',
                    },
                );
                return { ok => 1, token => undef };
            }

            my $token = $self->_create_identity_token(
                {
                    email_normalized => _column( $user, 'email_normalized' ),
                    metadata         => {
                        identifier_hash => _hash_value( $input->{identifier} ),
                        request_address_hash =>
                          _hash_value( $input->{request_address} ),
                    },
                    token_type  => 'password_reset',
                    ttl_seconds => $PASSWORD_RESET_TOKEN_SECONDS,
                    user_id     => _column( $user, 'id' ),
                }
            );
            $self->_record_identity_audit(
                action      => 'identity.password_reset.requested',
                actor_id    => _column( $user, 'id' ),
                target_type => $USER_AGGREGATE,
                target_id   => _column( $user, 'id' ),
                metadata    => {
                    request_address_hash =>
                      _hash_value( $input->{request_address} ),
                    token_id => $token->{token_id},
                    outcome  => 'issued',
                },
            );

            return { ok => 1, token => $token };
        }
    );
}

sub reset_password {
    my ( $self, $input ) = @_;

    my $password_error = _password_error( $input->{password} );
    return { ok => 0, error => $password_error } if $password_error;

    return $self->schema->txn_do(
        sub {
            my $token = $self->_consume_identity_token( 'password_reset',
                $input->{token} );
            return $token if !$token->{ok};

            my $user = $self->_find_user_by_id( $token->{user_id} );
            return { ok => 0, error => 'invalid_token' } if !$user;

            my $secret_hash =
              $self->password->hash_password( $input->{password} );
            my $now = $self->clock->now_iso8601;
            $self->_rotate_password_credential(
                {
                    secret_hash => $secret_hash,
                    user        => $user,
                    user_id     => _column( $user, 'id' ),
                }
            );
            _update_row(
                $user,
                {
                    password_hash => $secret_hash,
                    updated_at    => $now,
                }
            );
            $self->_revoke_user_sessions( _column( $user, 'id' ), $now );
            $self->_record_identity_audit(
                action      => 'identity.password_reset.completed',
                actor_id    => _column( $user, 'id' ),
                target_type => $USER_AGGREGATE,
                target_id   => _column( $user, 'id' ),
                metadata    => { token_id => $token->{token_id} },
            );

            return { ok => 1, user => $user };
        }
    );
}

sub change_password {
    my ( $self, $input ) = @_;

    my $password_error = _password_error( $input->{new_password} );
    return { ok => 0, error => $password_error } if $password_error;

    my $user = $self->_find_user_by_id( $input->{user_id} );
    return { ok => 0, error => 'not_found' } if !$user;

    my $credential =
      $self->_active_password_credential( _column( $user, 'id' ) );
    return { ok => 0, error => 'invalid_current_password' }
      if !$credential
      || !$self->password->verify_password( $input->{current_password},
        _column( $credential, 'secret_hash' ) );

    return $self->schema->txn_do(
        sub {
            my $secret_hash =
              $self->password->hash_password( $input->{new_password} );
            $self->_rotate_password_credential(
                {
                    secret_hash => $secret_hash,
                    user        => $user,
                    user_id     => _column( $user, 'id' ),
                }
            );
            _update_row(
                $user,
                {
                    password_hash => $secret_hash,
                    updated_at    => $self->clock->now_iso8601,
                }
            );
            $self->_record_identity_audit(
                action      => 'identity.password.changed',
                actor_id    => _column( $user, 'id' ),
                target_type => $USER_AGGREGATE,
                target_id   => _column( $user, 'id' ),
                metadata    => {},
            );

            return { ok => 1, user => $user };
        }
    );
}

sub request_email_change {
    my ( $self, $input ) = @_;

    my $email       = _normalize_identifier( $input->{email} );
    my $email_error = _email_error($email);
    return { ok => 0, error => $email_error } if $email_error;
    return { ok => 0, error => 'email_already_registered' }
      if $self->_email_taken( $email, $input->{user_id} );

    my $user = $self->_find_user_by_id( $input->{user_id} );
    return { ok => 0, error => 'not_found' } if !$user;

    return $self->schema->txn_do(
        sub {
            my $token = $self->_create_identity_token(
                {
                    email_normalized => $email,
                    metadata         => {
                        request_address_hash =>
                          _hash_value( $input->{request_address} ),
                    },
                    token_type  => 'email_change',
                    ttl_seconds => $EMAIL_CHANGE_TOKEN_SECONDS,
                    user_id     => _column( $user, 'id' ),
                }
            );
            $self->_record_identity_audit(
                action      => 'identity.email_change.requested',
                actor_id    => _column( $user, 'id' ),
                target_type => $USER_AGGREGATE,
                target_id   => _column( $user, 'id' ),
                metadata    => {
                    email_hash => _hash_value($email),
                    token_id   => $token->{token_id},
                },
            );

            return { ok => 1, token => $token };
        }
    );
}

sub confirm_email_change {
    my ( $self, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            my $token =
              $self->_consume_identity_token( 'email_change', $input->{token} );
            return $token if !$token->{ok};

            my $email = $token->{email_normalized};
            return { ok => 0, error => 'invalid_token' } if !$email;
            return { ok => 0, error => 'email_already_registered' }
              if $self->_email_taken( $email, $token->{user_id} );

            my $user = $self->_find_user_by_id( $token->{user_id} );
            return { ok => 0, error => 'invalid_token' } if !$user;

            my $now = $self->clock->now_iso8601;
            _update_row(
                $user,
                {
                    email_normalized  => $email,
                    email_verified_at => $now,
                    updated_at        => $now,
                }
            );
            $self->_record_identity_audit(
                action      => 'identity.email_change.confirmed',
                actor_id    => _column( $user, 'id' ),
                target_type => $USER_AGGREGATE,
                target_id   => _column( $user, 'id' ),
                metadata    => {
                    email_hash => _hash_value($email),
                    token_id   => $token->{token_id},
                },
            );

            return { ok => 1, user => $user };
        }
    );
}

sub revoke_session {
    my ( $self, $input ) = @_;

    my $session_id = $input->{session_id};
    my $user_id    = $input->{user_id};
    return { ok => 0, error => 'not_found' }
      if !defined $session_id || !length $session_id;

    my %query = ( session_id => $session_id );
    $query{user_id} = $user_id if defined $user_id && length $user_id;

    my $session = $self->schema->resultset('Session')->find( \%query );
    return { ok => 0, error => 'not_found' } if !$session;

    _update_row( $session, { revoked_at => $self->clock->now_iso8601 } );

    return { ok => 1, session => $session };
}

sub validate_session {
    my ( $self, $input ) = @_;

    my $session_id = $input->{session_id};
    my $user_id    = $input->{user_id};
    return { ok => 0, error => 'not_found' }
      if !defined $session_id
      || !length $session_id
      || !defined $user_id
      || !length $user_id;

    my $session = $self->schema->resultset('Session')->find(
        {
            session_id => $session_id,
            user_id    => $user_id,
        }
    );
    return { ok => 0, error => 'not_found' } if !$session;
    return { ok => 0, error => 'revoked' }
      if defined _column( $session, 'revoked_at' );

    my $now = $self->clock->now_iso8601;
    if ( _session_expired( $session, $now ) ) {
        _update_row( $session, { revoked_at => $now } );
        return { ok => 0, error => 'expired', session => $session };
    }

    _update_row( $session, { last_seen_at => $now } );

    return { ok => 1, session => $session };
}

sub preferred_locale_for_user {
    my ( $self, $input ) = @_;

    my $user = $self->_find_user_by_id( $input->{user_id} );
    return { ok => 0, error => 'not_found' } if !$user;

    return {
        ok               => 1,
        preferred_locale => _column( $user, 'preferred_locale' ),
        user             => $user,
    };
}

sub update_preferred_locale {
    my ( $self, $input ) = @_;

    my $user = $self->_find_user_by_id( $input->{user_id} );
    return { ok => 0, error => 'not_found' } if !$user;

    my $locale = _trim( $input->{preferred_locale} );
    return { ok => 0, error => 'locale_required' } if !length $locale;

    _update_row(
        $user,
        {
            preferred_locale => $locale,
            updated_at       => $self->clock->now_iso8601,
        }
    );

    return {
        ok               => 1,
        preferred_locale => $locale,
        user             => $user,
    };
}

sub preferred_theme_for_user {
    my ( $self, $input ) = @_;

    my $user = $self->_find_user_by_id( $input->{user_id} );
    return { ok => 0, error => 'not_found' } if !$user;

    return {
        ok              => 1,
        preferred_theme => _column( $user, 'preferred_theme' ),
        user            => $user,
    };
}

sub update_preferred_theme {
    my ( $self, $input ) = @_;

    my $user = $self->_find_user_by_id( $input->{user_id} );
    return { ok => 0, error => 'not_found' } if !$user;

    my $theme = _trim( $input->{preferred_theme} );
    return { ok => 0, error => 'theme_required' } if !length $theme;

    _update_row(
        $user,
        {
            preferred_theme => $theme,
            updated_at      => $self->clock->now_iso8601,
        }
    );

    return {
        ok              => 1,
        preferred_theme => $theme,
        user            => $user,
    };
}

sub _find_user_by_id {
    my ( $self, $user_id ) = @_;

    return if !defined $user_id || !length $user_id;

    return $self->schema->resultset('User')->find( { id => $user_id } );
}

sub _find_login_user {
    my ( $self, $identifier ) = @_;

    return if !length $identifier;

    my $users = $self->schema->resultset('User');

    return $users->find( { email_normalized => $identifier } )
      if $identifier =~ /[@]/msx;

    return $users->find( { username => $identifier } );
}

sub _active_password_credential {
    my ( $self, $user_id ) = @_;

    return if !defined $user_id || !length $user_id;

    return $self->schema->resultset('Credential')->search(
        {
            revoked_at => undef,
            type       => 'password',
            user_id    => $user_id,
        },
        {
            order_by => { -desc => 'created_at' },
            rows     => 1,
        }
    )->single;
}

sub _create_identity_token {
    my ( $self, $input ) = @_;

    my $created_at = $self->clock->now_iso8601;
    my $raw_token  = $self->session_tokens->issue_token;
    my $expires_at =
      _iso8601_from_epoch( $self->clock->now_epoch + $input->{ttl_seconds} );
    my $token_id   = $self->id_service->uuid;
    my $token_hash = $self->session_tokens->hash_token($raw_token);
    my $row        = $self->schema->resultset('IdentityToken')->create(
        {
            created_at       => $created_at,
            email_normalized => $input->{email_normalized},
            expires_at       => $expires_at,
            metadata         => $input->{metadata} || {},
            token_hash       => $token_hash,
            token_id         => $token_id,
            token_type       => $input->{token_type},
            used_at          => undef,
            user_id          => $input->{user_id},
        }
    );

    return {
        expires_at => $expires_at,
        raw_token  => $raw_token,
        row        => $row,
        token_hash => $token_hash,
        token_id   => $token_id,
    };
}

sub _consume_identity_token {
    my ( $self, $token_type, $raw_token ) = @_;

    my $token_hash = $self->session_tokens->hash_token( _trim($raw_token) );
    $self->_lock_identity_token_hash($token_hash);

    my $identity_tokens = $self->schema->resultset('IdentityToken');
    my $row             = $identity_tokens->search(
        {
            token_hash => $token_hash,
            token_type => $token_type,
        },
        { rows => 1 }
    )->single;
    my $validated = $self->_validate_identity_token($row);
    return $validated if !$validated->{ok};

    my $used_at = $self->clock->now_iso8601;
    _update_row( $row, { used_at => $used_at } );

    return {
        ok               => 1,
        email_normalized => _column( $row, 'email_normalized' ),
        row              => $row,
        token_id         => _column( $row, 'token_id' ),
        user_id          => _column( $row, 'user_id' ),
    };
}

sub _validate_identity_token {
    my ( $self, $row ) = @_;

    return { ok => 0, error => 'invalid_token' } if !$row;
    return { ok => 0, error => 'token_used' }
      if defined _column( $row, 'used_at' );
    return { ok => 0, error => 'token_expired' }
      if ( _column( $row, 'expires_at' ) || q{} ) le $self->clock->now_iso8601;

    return { ok => 1 };
}

sub _lock_identity_token_hash {
    my ( $self, $token_hash ) = @_;

    my $dbh = _schema_dbh( $self->schema );
    return if !$dbh;

    $dbh->selectrow_array(
        'SELECT token_id FROM identity_tokens WHERE token_hash = ? FOR UPDATE',
        undef, $token_hash
    );

    return;
}

sub _rotate_password_credential {
    my ( $self, $input ) = @_;

    my $now         = $self->clock->now_iso8601;
    my $user_id     = $input->{user_id};
    my $credentials = $self->schema->resultset('Credential');
    my @active      = $credentials->search(
        {
            revoked_at => undef,
            type       => 'password',
            user_id    => $user_id,
        }
    )->all;

    for my $credential (@active) {
        _update_row( $credential, { revoked_at => $now } );
    }

    return $credentials->create(
        {
            id          => $self->id_service->uuid,
            secret_hash => $input->{secret_hash},
            type        => 'password',
            user_id     => $user_id,
        }
    );
}

sub _revoke_user_sessions {
    my ( $self, $user_id, $revoked_at ) = @_;

    my $sessions = $self->schema->resultset('Session');
    my @sessions = $sessions->search(
        {
            revoked_at => undef,
            user_id    => $user_id,
        }
    )->all;

    for my $session (@sessions) {
        _update_row( $session, { revoked_at => $revoked_at } );
    }

    return;
}

sub _email_taken {
    my ( $self, $email, $current_user_id ) = @_;

    my $existing =
      $self->schema->resultset('User')->find( { email_normalized => $email } );
    return 0 if !$existing;

    my $existing_id = _column( $existing, 'id' );
    return 0
      if defined $existing_id
      && defined $current_user_id
      && $existing_id eq $current_user_id;

    return 1;
}

sub _create_session {
    my ( $self, $user, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            my $raw_token  = $self->session_tokens->issue_token;
            my $created_at = $self->clock->now_iso8601;
            my $expires_at =
              _iso8601_from_epoch(
                $self->clock->now_epoch + $self->session_seconds );
            my $session = $self->schema->resultset('Session')->create(
                {
                    session_id   => $self->id_service->uuid,
                    user_id      => _column( $user, 'id' ),
                    session_hash =>
                      $self->session_tokens->hash_token($raw_token),
                    created_at      => $created_at,
                    last_seen_at    => $created_at,
                    expires_at      => $expires_at,
                    revoked_at      => undef,
                    ip_hash         => _hash_value( $input->{request_address} ),
                    user_agent_hash => _hash_value( $input->{user_agent} ),
                }
            );

            return { session => $session };
        }
    );
}

sub _record_event {
    my ( $self, $user, $correlation_id ) = @_;

    my $idempotency_key = join q{:}, 'user.registered', $user->{id};
    $self->recorder->record_event(
        event_type        => 'user.registered',
        schema_version    => $SCHEMA_VERSION,
        aggregate_type    => $USER_AGGREGATE,
        aggregate_id      => $user->{id},
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $user->{id},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   => $idempotency_key,
        payload           => { username => $user->{username} },
    );

    return;
}

sub _record_audit {
    my ( $self, $user, $correlation_id ) = @_;

    $self->recorder->record_audit(
        action         => 'user.registered',
        schema_version => $SCHEMA_VERSION,
        actor_id       => $user->{id},
        target_type    => $USER_AGGREGATE,
        target_id      => $user->{id},
        correlation_id => $correlation_id,
        metadata       => { username => $user->{username} },
    );

    return;
}

sub _record_identity_audit {
    my ( $self, %input ) = @_;

    $self->recorder->record_audit(
        action         => $input{action},
        actor_id       => $input{actor_id},
        metadata       => $input{metadata} || {},
        schema_version => $SCHEMA_VERSION,
        target_id      => $input{target_id},
        target_type    => $input{target_type},
    );

    return;
}

sub _normalize_identifier {
    my ($value) = @_;

    return lc _trim($value);
}

sub _email_error {
    my ($email) = @_;

    return 'email_required' if !length $email;
    return 'email_invalid'
      if $email !~
      /\A [[:alnum:]._%+-]+ [@] [[:alnum:].-]+ [.] [[:alpha:]]{2,} \z/imsx;

    return;
}

sub _password_error {
    my ($password) = @_;

    return 'password_required' if !defined $password || !length $password;
    return 'password_too_short'
      if length $password < $MINIMUM_PASSWORD_LENGTH;

    return;
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

sub _invalid_login {
    return { ok => 0, error => 'invalid_credentials' };
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->{$column}           if ref $row eq 'HASH';
    return $row->get_column($column) if $row && $row->can('get_column');

    return;
}

sub _update_row {
    my ( $row, $values ) = @_;

    if ( ref $row eq 'HASH' ) {
        for my $key ( keys %{$values} ) {
            $row->{$key} = $values->{$key};
        }
        return $row;
    }

    return $row->update($values);
}

sub _session_expired {
    my ( $session, $now ) = @_;

    my $expires_at = _column( $session, 'expires_at' );
    return 1 if !defined $expires_at || !length $expires_at;

    return $expires_at le $now ? 1 : 0;
}

sub _hash_value {
    my ($value) = @_;

    return if !defined $value || !length $value;

    return sha256_hex($value);
}

sub _schema_dbh {
    my ($schema) = @_;

    my $storage = eval { $schema->storage };
    return if !$storage || !$storage->can('dbh');

    my $dbh = eval { $storage->dbh };
    return $dbh;
}

sub _iso8601_from_epoch {
    my ($epoch) = @_;

    return strftime '%Y-%m-%dT%H:%M:%SZ', gmtime $epoch;
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::Store - Identity persistence boundary.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Identity::Store->new(schema => $schema);

=head1 DESCRIPTION

Persists identity workflow records through DBIx::Class resultsets while keeping
controllers and ORM result classes free of workflow logic.

=head1 SUBROUTINES/METHODS

=head2 create_registration

Persists a prepared registration, password credential, event, and audit record.

=head1 DIAGNOSTICS

Storage errors are reported by the schema layer.

=head1 CONFIGURATION AND ENVIRONMENT

Receives a schema object from application wiring.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Mojo::Base>, L<GPForum::Service::Clock>, and
L<GPForum::Service::Id>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

This service currently handles registration persistence only.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
