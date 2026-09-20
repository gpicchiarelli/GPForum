package GPForum::Service::Identity::SessionStore;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Identity::Support;
use GPForum::Service::SessionToken;

our $VERSION = '0.001';

const my $SESSION_DAYS                   => 30;
const my $DAY_SECONDS                    => 86_400;
const my $ID_CONSTRAINT                  => 'sessions_pkey';
const my $DEFAULT_TOUCH_INTERVAL_SECONDS => 300;

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has schema          => undef;
has session_seconds => sub { return $SESSION_DAYS * $DAY_SECONDS; };
has session_touch_interval_seconds =>
  sub { return $DEFAULT_TOUCH_INTERVAL_SECONDS; };
has session_tokens => sub { return GPForum::Service::SessionToken->new; };
has support        => sub { return GPForum::Service::Identity::Support->new; };

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

    my $existing = $self->support->column( $session, 'revoked_at' );
    if ( defined $existing ) {
        return {
            ok      => 1,
            session => $session,
            skipped => 1,
        };
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

    return $self->_insert_or_retry_session(
        $self->_session_row( $user, $input ) );
}

sub _insert_or_retry_session {
    my ( $self, $row ) = @_;

    my $created = eval { return $self->_create_session_row($row); };
    if ($created) {
        return { session => $created };
    }

    return $self->_session_after_conflict( $row, $EVAL_ERROR );
}

sub _session_after_conflict {
    my ( $self, $row, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( _session_id_conflict($error) ) {
        return $self->_retry_or_reuse_session($row);
    }

    return $self->_retry_session_once($row);
}

sub _session_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _retry_or_reuse_session {
    my ( $self, $row ) = @_;

    my $stored = $self->_session_by_id( $row->{session_id} );
    if ( $self->_same_open_session( $stored, $row ) ) {
        return $self->_skipped_session($stored);
    }

    return $self->_retry_session_id($row);
}

sub _same_open_session {
    my ( $self, $stored, $row ) = @_;

    if ( !$stored ) {
        return 0;
    }
    if (
        !_same_text(
            $self->support->column( $stored, 'user_id' ),
            $row->{user_id}
        )
      )
    {
        return 0;
    }

    return _same_text( $self->support->column( $stored, 'session_hash' ),
        $row->{session_hash} );
}

sub _skipped_session {
    my ( $self, $stored ) = @_;

    return {
        session => $stored,
        skipped => 1,
    };
}

sub _session_by_id {
    my ( $self, $session_id ) = @_;

    return $self->_sessions->find( { session_id => $session_id } );
}

sub _same_text {
    my ( $stored, $candidate ) = @_;

    if ( !defined $stored || !defined $candidate ) {
        return 0;
    }

    return $stored eq $candidate ? 1 : 0;
}

sub _retry_session_id {
    my ( $self, $row ) = @_;

    my $created = eval {
        return $self->_create_session_row( $self->_reissued_session_id($row) );
    };
    if ($created) {
        return { session => $created };
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _reissued_session_id {
    my ( $self, $row ) = @_;

    return { %{$row}, session_id => $self->id_service->uuid };
}

sub _retry_session_once {
    my ( $self, $row ) = @_;

    my $created = eval {
        return $self->_create_session_row( $self->_rehashed_session($row) );
    };
    if ($created) {
        return { session => $created };
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _create_session_row {
    my ( $self, $row ) = @_;

    return $self->_sessions->create($row);
}

sub _rehashed_session {
    my ( $self, $row ) = @_;

    my $raw_token = $self->session_tokens->issue_token;

    return {
        %{$row}, session_hash => $self->session_tokens->hash_token($raw_token),
    };
}

sub _session_row {
    my ( $self, $user, $input ) = @_;

    my $created_at = $self->clock->now_iso8601;
    my $raw_token  = $self->session_tokens->issue_token;

    return {
        created_at => $created_at,
        expires_at => $self->support->iso8601_from_epoch(
            $self->clock->now_epoch + $self->session_seconds
        ),
        ip_hash      => $self->support->hash_value( $input->{request_address} ),
        last_seen_at => $created_at,
        revoked_at   => undef,
        session_hash => $self->session_tokens->hash_token($raw_token),
        session_id   => $self->id_service->uuid,
        user_agent_hash => $self->support->hash_value( $input->{user_agent} ),
        user_id         => $self->support->column( $user, 'id' ),
    };
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

    if ( $self->_session_needs_touch( $session, $now ) ) {
        $self->support->update_row( $session, { last_seen_at => $now } );
    }
    return { ok => 1, session => $session };
}

sub _session_needs_touch {
    my ( $self, $session, $now ) = @_;

    my $last_seen = $self->support->epoch_from_timestamp(
        $self->support->column( $session, 'last_seen_at' ) );
    my $current = $self->support->epoch_from_timestamp($now);
    if ( !defined $last_seen || !defined $current ) {
        return 1;
    }

    return $current - $last_seen >= $self->session_touch_interval_seconds
      ? 1
      : 0;
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

Creates a hashed server-side session for a user. A unique C<session_hash>
collision remints the hash once and does not return another user's session.
A unique C<session_id> collision remints the id once and does not return
another user's session. A leftover unique C<session_id> with this user and
hash reuses the session.

=head2 revoke_session

Revokes one session by id. A second revoke of the same session keeps the
original timestamp and returns C<skipped>.

=head2 validate_session

Accepts a live session, or rejects revoked/expired rows. The revoked and
expired checks run on every call and only read the row. C<last_seen_at> is
written only when the stored value is at least
C<session_touch_interval_seconds> old (default 300), so an authenticated
request does not turn into a session UPDATE every time. Unparseable
C<last_seen_at> values are refreshed.

=head2 revoke_user_sessions

Revokes every active session for a user.

=head1 DIAGNOSTICS

Missing or invalid sessions return C<not_found>, C<revoked>, or C<expired>.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a DBIx::Class schema with a C<Session> resultset. The
C<session_touch_interval_seconds> attribute is wired from
C<GPFORUM_SESSION_TOUCH_INTERVAL_SECONDS> through L<GPForum::Config>.

=head1 DEPENDENCIES

Uses L<GPForum::Infrastructure::UniqueConflict>,
L<GPForum::Service::Identity::Support>, and L<GPForum::Service::SessionToken>.

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
