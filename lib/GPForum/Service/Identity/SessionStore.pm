package GPForum::Service::Identity::SessionStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Identity::Support;
use GPForum::Service::SessionToken;

our $VERSION = '0.001';

const my $SESSION_DAYS => 30;
const my $DAY_SECONDS  => 86_400;

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has schema          => undef;
has session_seconds => sub { return $SESSION_DAYS * $DAY_SECONDS; };
has session_tokens  => sub { return GPForum::Service::SessionToken->new; };
has support         => sub { return GPForum::Service::Identity::Support->new; };

sub create_session {
    my ( $self, $user, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            return $self->_insert_session( $user, $input );
        }
    );
}

sub revoke_session {
    my ( $self, $input ) = @_;

    if ( !$self->support->has_text( $input->{session_id} ) ) {
        return { ok => 0, error => 'not_found' };
    }

    my $session = $self->_find_session($input);
    if ( !$session ) {
        return { ok => 0, error => 'not_found' };
    }

    $self->support->update_row( $session,
        { revoked_at => $self->clock->now_iso8601 } );

    return { ok => 1, session => $session };
}

sub validate_session {
    my ( $self, $input ) = @_;

    if ( !$self->_session_ids_present($input) ) {
        return { ok => 0, error => 'not_found' };
    }

    return $self->_refresh_or_reject_session($input);
}

sub revoke_user_sessions {
    my ( $self, $user_id, $revoked_at ) = @_;

    my @sessions = $self->_sessions->search(
        {
            revoked_at => undef,
            user_id    => $user_id,
        }
    )->all;

    for my $session (@sessions) {
        $self->support->update_row( $session, { revoked_at => $revoked_at } );
    }

    return;
}

sub _insert_session {
    my ( $self, $user, $input ) = @_;

    my $created_at = $self->clock->now_iso8601;
    my $raw_token  = $self->session_tokens->issue_token;
    my $session    = $self->_sessions->create(
        {
            created_at => $created_at,
            expires_at => $self->support->iso8601_from_epoch(
                $self->clock->now_epoch + $self->session_seconds
            ),
            ip_hash => $self->support->hash_value( $input->{request_address} ),
            last_seen_at    => $created_at,
            revoked_at      => undef,
            session_hash    => $self->session_tokens->hash_token($raw_token),
            session_id      => $self->id_service->uuid,
            user_agent_hash =>
              $self->support->hash_value( $input->{user_agent} ),
            user_id => $self->support->column( $user, 'id' ),
        }
    );

    return { session => $session };
}

sub _find_session {
    my ( $self, $input ) = @_;

    my %query = ( session_id => $input->{session_id} );
    if ( $self->support->has_text( $input->{user_id} ) ) {
        $query{user_id} = $input->{user_id};
    }

    return $self->_sessions->find( \%query );
}

sub _session_ids_present {
    my ( $self, $input ) = @_;

    if ( !$self->support->has_text( $input->{session_id} ) ) {
        return 0;
    }
    if ( !$self->support->has_text( $input->{user_id} ) ) {
        return 0;
    }

    return 1;
}

sub _refresh_or_reject_session {
    my ( $self, $input ) = @_;

    my $session = $self->_sessions->find(
        {
            session_id => $input->{session_id},
            user_id    => $input->{user_id},
        }
    );
    if ( !$session ) {
        return { ok => 0, error => 'not_found' };
    }

    return $self->_evaluate_session($session);
}

sub _evaluate_session {
    my ( $self, $session ) = @_;

    if ( defined $self->support->column( $session, 'revoked_at' ) ) {
        return { ok => 0, error => 'revoked' };
    }

    my $now = $self->clock->now_iso8601;
    if ( $self->_session_expired( $session, $now ) ) {
        $self->support->update_row( $session, { revoked_at => $now } );
        return { ok => 0, error => 'expired', session => $session };
    }

    $self->support->update_row( $session, { last_seen_at => $now } );
    return { ok => 1, session => $session };
}

sub _session_expired {
    my ( $self, $session, $now ) = @_;

    my $expires_at = $self->support->column( $session, 'expires_at' );
    if ( !$self->support->has_text($expires_at) ) {
        return 1;
    }

    return $expires_at le $now ? 1 : 0;
}

sub _sessions {
    my ($self) = @_;

    return $self->schema->resultset('Session');
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::SessionStore - Server session persistence.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Identity::SessionStore->new(
        schema => $schema,
    );

=head1 DESCRIPTION

Creates, validates, and revokes identity sessions.

=head1 SUBROUTINES/METHODS

=head2 create_session

Creates a hashed server-side session for a user.

=head2 revoke_session

Revokes one session by id.

=head2 validate_session

Accepts a live session and refreshes last-seen, or rejects revoked/expired
rows.

=head2 revoke_user_sessions

Revokes every active session for a user.

=head1 DIAGNOSTICS

Missing or invalid sessions return C<not_found>, C<revoked>, or C<expired>.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a DBIx::Class schema with a C<Session> resultset.

=head1 DEPENDENCIES

Uses L<GPForum::Service::Identity::Support> and L<GPForum::Service::SessionToken>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Session tokens are hashed before persistence; the raw token is not returned.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
