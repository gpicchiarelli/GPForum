# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::SessionStore;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::PreparedQuery;
use GPForum::Infrastructure::Id;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Identity::Support;
use GPForum::Service::SessionToken;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $SESSION_DAYS                   => 30;
const my $DAY_SECONDS                    => 86_400;
const my $ID_CONSTRAINT                  => 'sessions_pkey';
const my $DEFAULT_TOUCH_INTERVAL_SECONDS => 300;

# A session is revoked at the time given, or at its own creation when that
# is later. sessions_revoked_after_created_check refuses a revocation stamped
# before the creation, and the time given can be: a reset reads its clock
# before it waits for a login holding the credential, whose session is then
# stamped a second later, and another host's clock can run behind the one
# that opened the session. The revocation failed, the reset or the logout
# with it, and the session stayed signed in.
const my $NOT_BEFORE_CREATION => 'GREATEST(CAST(? AS timestamptz), created_at)';

has clock      => sub { return GPForum::Service::Clock->new; };
has prepared   => sub { return GPForum::Infrastructure::PreparedQuery->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
__PACKAGE__->requires(qw(schema));
has session_seconds => sub { return $SESSION_DAYS * $DAY_SECONDS; };
has session_touch_interval_seconds =>
  sub { return $DEFAULT_TOUCH_INTERVAL_SECONDS; };
has session_tokens => sub { return GPForum::Service::SessionToken->new; };
has support        => sub { return GPForum::Service::Identity::Support->new; };

sub create_session ( $self, $user, $input ) {
    return $self->schema->txn_do(
        sub {
            return $self->_insert_session( $user, $input );
        }
    );
}

sub revoke_session ( $self, $input ) {
    if ( !$self->support->has_text( $input->{session_id} ) ) {
        return { ok => 0, error => 'not_found' };
    }

    my %query = ( session_id => $input->{session_id} );
    if ( $self->support->has_text( $input->{user_id} ) ) {
        $query{user_id} = $input->{user_id};
    }
    my $session = $self->_session_where( \%query );
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

    # Only while it is still live, so a revocation that landed in between
    # keeps its time, as a second revoke does.
    my $revoked = $self->_revoke_sessions(
        {
            revoked_at => undef,
            session_id => $self->support->column( $session, 'session_id' ),
        },
        $self->clock->now_iso8601
    );
    if ( !$revoked ) {
        return {
            ok      => 1,
            session => $session,
            skipped => 1,
        };
    }

    return { ok => 1, session => $session };
}

# A session is valid for the member it belongs to, with the token whose hash
# it stores, unrevoked and unexpired. An expired one is revoked when seen; a
# valid one is touched at most once per touch interval.
sub validate_session ( $self, $input ) {
    if (   !$self->support->has_text( $input->{session_id} )
        || !$self->support->has_text( $input->{user_id} ) )
    {
        return { ok => 0, error => 'not_found' };
    }
    my $session = $self->_session_where(
        {
            session_id => $input->{session_id},
            user_id    => $input->{user_id},
        }
    );
    if ( !$session ) {
        return { ok => 0, error => 'not_found' };
    }
    if ( !$self->_token_matches( $session, $input->{session_token} ) ) {
        return { ok => 0, error => 'invalid_token' };
    }
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

# $keep_session_id lets a password CHANGE evict every other device while
# leaving the browser the user is currently typing in signed in. A password
# RESET passes nothing, because there is no session to keep. One UPDATE: a
# session committed since the caller's last statement is revoked with the
# rest.
sub revoke_user_sessions ( $self, $user_id, $revoked_at,
    $keep_session_id = undef )
{
    my %live = (
        revoked_at => undef,
        user_id    => $user_id,
    );
    if ( GPForum::Infrastructure::Id->is_uuid($keep_session_id) ) {
        $live{session_id} = { q{!=} => $keep_session_id };
    }

    return $self->_revoke_sessions( \%live, $revoked_at );
}

# Revokes the sessions the condition selects, none earlier than it was
# created, and answers how many.
sub _revoke_sessions ( $self, $condition, $revoked_at ) {
    my $revoked = $self->_sessions->search_rs($condition)
      ->update( { revoked_at => \[ $NOT_BEFORE_CREATION, $revoked_at ] } );

    return 0 + ( $revoked || 0 );
}

# The raw token travels back to the caller so it can reach the cookie. It used
# to be minted here, hashed into the row, and dropped on the floor: the
# session_hash column then held the digest of a secret nobody possessed, and
# nothing ever compared it. See docs/QUALITY_PROGRAM.md 2.1.
#
# A minted session id already stored is either this very session, committed
# by an earlier attempt, or another one, and then a new id is minted. Any
# other conflict is on the token's hash, and the token is reminted: that one,
# not the first, is the token whose hash is stored and must reach the cookie.
sub _insert_session ( $self, $user, $input ) {
    my $raw_token  = $self->session_tokens->issue_token;
    my $created_at = $self->clock->now_iso8601;
    my $row        = {
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
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_sessions->create($row); } );
    if ($created) {
        return { session => $created, session_token => $raw_token };
    }

    my $conflict = GPForum::X::Conflict->caught($error);
    if ( !$conflict ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( $conflict->on($ID_CONSTRAINT) ) {
        my $stored =
          $self->_sessions->find( { session_id => $row->{session_id} } );
        if ( $self->_same_open_session( $stored, $row ) ) {
            return {
                session       => $stored,
                session_token => $raw_token,
                skipped       => 1,
            };
        }
        $row = { %{$row}, session_id => $self->id_service->uuid };
    }
    else {
        $raw_token = $self->session_tokens->issue_token;
        $row       = {
            %{$row},
            session_hash => $self->session_tokens->hash_token($raw_token),
        };
    }

    my ( $retried, $retry_error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_sessions->create($row); } );
    if ($retried) {
        return { session => $retried, session_token => $raw_token };
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($retry_error);
}

# The same member and the same token hash: the row is this session.
sub _same_open_session ( $self, $stored, $row ) {
    if ( !$stored ) {
        return 0;
    }
    for my $column (qw(user_id session_hash)) {
        my $value = $self->support->column( $stored, $column );
        if (   !defined $value
            || !defined $row->{$column}
            || $value ne $row->{$column} )
        {
            return 0;
        }
    }

    return 1;
}

# A session looked up by its id and its member's. DBIx::Class's find keeps
# only the columns of a unique constraint the values satisfy -- here the
# primary key -- and drops the rest from the WHERE clause, so a find on both
# found the session whoever presented it: one member could revoke or
# validate another's. A search keeps every column it is given.
sub _session_where ( $self, $query ) {
    my $sessions = $self->_sessions;
    my @columns  = sort keys %{$query};

    return $self->prepared->row(
        schema    => $self->schema,
        shape     => 'session:by-' . join( q{,}, @columns ),
        source    => 'Session',
        resultset => sub {
            return $sessions->search_rs(
                { map { ( "me.$_" => $query->{$_} ) } @columns } );
        },
        fallback =>
          sub { return [ $sessions->search_rs($query)->single // () ]; },
        values => { map { ( "me.$_" => $query->{$_} ) } @columns },
    );
}

# The signed cookie already proves the browser holds one this application
# issued. This proves it holds the secret for THIS session as well, so a
# forged or replayed cookie is not enough on its own, and it is what makes the
# session_hash column mean something.
sub _token_matches ( $self, $session, $presented ) {
    my $stored = $self->support->column( $session, 'session_hash' );
    if ( !$self->support->has_text($stored) ) {
        return 0;
    }
    if ( !$self->support->has_text($presented) ) {
        return 0;
    }

    return _same_digest( $stored,
        $self->session_tokens->hash_token($presented) );
}

# Compared without an early exit. The digests are public-ish, so a leak here
# would reveal a prefix of a hash rather than of the token, but a comparison
# whose timing depends on a secret is not worth defending.
sub _same_digest ( $stored, $presented ) {
    return 0 if length $stored != length $presented;

    my $difference = 0;
    for my $position ( 0 .. length($stored) - 1 ) {
        $difference |= ord( substr $stored, $position, 1 ) ^
          ord( substr $presented, $position, 1 );
    }

    return $difference == 0 ? 1 : 0;
}

sub _session_needs_touch ( $self, $session, $now ) {
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

sub _session_expired ( $self, $session, $now ) {
    my $expires_at    = $self->support->column( $session, 'expires_at' );
    my $expires_epoch = $self->support->epoch_from_timestamp($expires_at);
    if ( !defined $expires_epoch ) {
        return 1;
    }

    my $now_epoch = $self->support->epoch_from_timestamp($now);
    if ( !defined $now_epoch ) {
        $now_epoch = $self->clock->now_epoch;
    }

    return $expires_epoch <= $now_epoch ? 1 : 0;
}

sub _sessions ($self) {
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

Revokes one session by id. Given a C<user_id>, the session must belong to
that member or the answer is C<not_found>; the member is matched in the
query, not after the row is fetched. A second revoke of the same session,
or one a concurrent revocation beat, keeps the original timestamp and
returns C<skipped>. The session is revoked at the store's clock, or at its
own C<created_at> when that is later.

=head2 validate_session

Accepts a live session, or rejects revoked/expired rows. The session is
looked up by its id and its member's together, so a session presented under
another member's id is C<not_found>. The revoked and expired checks run on
every call and only read the row. C<last_seen_at> is written only when the
stored value is at least C<session_touch_interval_seconds> old (default
300), so an authenticated request does not turn into a session UPDATE every
time. Unparseable C<last_seen_at> values are refreshed.

=head2 revoke_user_sessions

Takes a user id, a revocation time and, optionally, a session id to keep.
Revokes every live session of the user in one UPDATE and returns how many it
revoked. With the session id it keeps that one session, which is what a
password change uses to evict other devices without signing the user out
where they are. Each session is revoked at the time given, or at its own
C<created_at> when that is later, so a session a concurrent login committed
after the caller read its clock is revoked rather than failing
C<sessions_revoked_after_created_check>.

=head1 DIAGNOSTICS

Missing or invalid sessions return C<not_found>, C<revoked>, or C<expired>.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a DBIx::Class schema with a C<Session> resultset. The
C<session_touch_interval_seconds> attribute is wired from
C<GPFORUM_SESSION_TOUCH_INTERVAL_SECONDS> through L<GPForum::Config>.

=head1 DEPENDENCIES

Uses L<GPForum::Infrastructure::Id>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::X::Conflict>,
L<GPForum::Service::Identity::Support>, and L<GPForum::Service::SessionToken>.

Extends L<GPForum::Base>: built without C<schema> it throws
L<GPForum::X::Argument>.

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
