# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Identity::SessionStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

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
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has schema          => undef;
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

sub validate_session ( $self, $input ) {
    if ( !$self->_session_ids_present($input) ) {
        return { ok => 0, error => 'not_found' };
    }

    return $self->_refresh_or_reject_session($input);
}

# $keep_session_id lets a password CHANGE evict every other device while
# leaving the browser the user is currently typing in signed in. A password
# RESET passes nothing, because there is no session to keep.
sub revoke_user_sessions ( $self, $user_id, $revoked_at,
    $keep_session_id = undef )
{
    my @sessions = $self->_sessions->search_rs(
        {
            revoked_at => undef,
            user_id    => $user_id,
        }
    )->all;

    my $revoked = 0;
    for my $session (@sessions) {
        next if _is_kept( $self, $session, $keep_session_id );
        $self->support->update_row( $session, { revoked_at => $revoked_at } );
        $revoked++;
    }

    return $revoked;
}

sub _is_kept ( $self, $session, $keep_session_id ) {
    if ( !defined $keep_session_id || !length $keep_session_id ) {
        return 0;
    }

    my $id = $self->support->column( $session, 'session_id' );

    return defined $id && $id eq $keep_session_id ? 1 : 0;
}

# The raw token travels back to the caller so it can reach the cookie. It used
# to be minted here, hashed into the row, and dropped on the floor: the
# session_hash column then held the digest of a secret nobody possessed, and
# nothing ever compared it. See docs/QUALITY_PROGRAM.md 2.1.
sub _insert_session ( $self, $user, $input ) {
    my $raw_token = $self->session_tokens->issue_token;
    my $created =
      $self->_insert_or_retry_session(
        $self->_session_row( $user, $input, $raw_token ) );

    # A retry after a hash collision remints the token; that one, not the
    # first, is the token whose hash is stored and must reach the cookie.
    return { %{$created},
        session_token => $created->{session_token} // $raw_token, };
}

sub _insert_or_retry_session ( $self, $row ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_session_row($row); },
      );
    if ($created) {
        return { session => $created };
    }

    return $self->_session_after_conflict( $row, $error );
}

sub _session_after_conflict ( $self, $row, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( _session_id_conflict($error) ) {
        return $self->_retry_or_reuse_session($row);
    }

    return $self->_retry_session_once($row);
}

sub _session_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _retry_or_reuse_session ( $self, $row ) {
    my $stored = $self->_session_by_id( $row->{session_id} );
    if ( $self->_same_open_session( $stored, $row ) ) {
        return $self->_skipped_session($stored);
    }

    return $self->_retry_session_id($row);
}

sub _same_open_session ( $self, $stored, $row ) {
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

sub _skipped_session ( $self, $stored ) {
    return {
        session => $stored,
        skipped => 1,
    };
}

sub _session_by_id ( $self, $session_id ) {
    return $self->_sessions->find( { session_id => $session_id } );
}

sub _same_text ( $stored, $candidate ) {
    if ( !defined $stored || !defined $candidate ) {
        return 0;
    }

    return $stored eq $candidate ? 1 : 0;
}

sub _retry_session_id ( $self, $row ) {
    my ( $created, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            return $self->_create_session_row(
                $self->_reissued_session_id($row) );
        },
    );
    if ($created) {
        return { session => $created };
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reissued_session_id ( $self, $row ) {
    return { %{$row}, session_id => $self->id_service->uuid };
}

sub _retry_session_once ( $self, $row ) {
    my $reissued;
    my ( $created, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            return $self->_create_session_row(
                $self->_rehashed_session( $row, \$reissued ) );
        },
    );
    if ($created) {
        return { session => $created, session_token => $reissued };
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _create_session_row ( $self, $row ) {
    return $self->_sessions->create($row);
}

# A retry re-mints the token, so the caller has to be told the new one or the
# cookie would carry a token whose hash is no longer stored.
sub _rehashed_session ( $self, $row, $issued ) {
    my $raw_token = $self->session_tokens->issue_token;
    ${$issued} = $raw_token;

    return {
        %{$row}, session_hash => $self->session_tokens->hash_token($raw_token),
    };
}

sub _session_row ( $self, $user, $input, $raw_token ) {
    my $created_at = $self->clock->now_iso8601;

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

sub _find_session ( $self, $input ) {
    my %query = ( session_id => $input->{session_id} );
    if ( $self->support->has_text( $input->{user_id} ) ) {
        $query{user_id} = $input->{user_id};
    }

    return $self->_sessions->find( \%query );
}

sub _session_ids_present ( $self, $input ) {
    if ( !$self->support->has_text( $input->{session_id} ) ) {
        return 0;
    }
    if ( !$self->support->has_text( $input->{user_id} ) ) {
        return 0;
    }

    return 1;
}

sub _refresh_or_reject_session ( $self, $input ) {
    my $session = $self->_sessions->find(
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

    return $self->_evaluate_session($session);
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

sub _evaluate_session ( $self, $session ) {
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

Revokes every live session for the user and returns how many it revoked. With a
fourth argument it keeps that one session, which is what a password change uses
to evict other devices without signing the user out where they are.

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
