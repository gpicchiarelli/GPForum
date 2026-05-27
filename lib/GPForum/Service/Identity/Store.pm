package GPForum::Service::Identity::Store;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use Mojo::Base -base;
use POSIX qw(strftime);

use GPForum::Service::Clock;
use GPForum::Service::Id;
use GPForum::Service::Password;
use GPForum::Service::SessionToken;

our $VERSION = '0.001';

const my $USER_AGGREGATE => 'user';
const my $SCHEMA_VERSION => 1;
const my $SESSION_DAYS   => 30;
const my $DAY_SECONDS    => 86_400;

has schema          => undef;
has clock           => sub { return GPForum::Service::Clock->new; };
has id_service      => sub { return GPForum::Service::Id->new; };
has password        => sub { return GPForum::Service::Password->new; };
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

    my $event_id        = $self->id_service->uuid;
    my $idempotency_key = join q{:}, 'user.registered', $user->{id};

    $self->schema->resultset('EventLog')->create(
        {
            event_id          => $event_id,
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
            metadata          => {},
        }
    );

    return;
}

sub _record_audit {
    my ( $self, $user, $correlation_id ) = @_;

    $self->schema->resultset('AuditLog')->create(
        {
            audit_id       => $self->id_service->uuid,
            action         => 'user.registered',
            schema_version => $SCHEMA_VERSION,
            actor_id       => $user->{id},
            target_type    => $USER_AGGREGATE,
            target_id      => $user->{id},
            correlation_id => $correlation_id,
            metadata       => { username => $user->{username} },
        }
    );

    return;
}

sub _normalize_identifier {
    my ($value) = @_;

    return lc _trim($value);
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
