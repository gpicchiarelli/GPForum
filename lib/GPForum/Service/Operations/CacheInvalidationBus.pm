# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::CacheInvalidationBus;

use strict;
use warnings;

use Const::Fast;
use JSON::MaybeXS ();
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::PgNotifications;

our $VERSION = '0.001';

const my $DEFAULT_CHANNEL => 'gpforum_cache_invalidation';

# NOTIFY refuses a payload over 8000 bytes, and losing an invalidation is worse
# than over-invalidating, so an oversized batch degrades to "drop everything"
# rather than being silently truncated.
const my $MAX_PAYLOAD_BYTES => 7_500;

has channel => $DEFAULT_CHANNEL;
has codec   => sub {
    return JSON::MaybeXS->new( canonical => 1, utf8 => 1 );
};
has schema => undef;

# The process's one queue for its handle, shared with the realtime listener
# (Bootstrap injects it). Reading the handle directly took the listener's
# notifications and let the listener take ours.
has notifications => sub ($self) {
    return GPForum::Infrastructure::PgNotifications->new(
        schema => $self->schema );
};
has stats => sub {
    return {
        applied          => 0,
        gaps             => 0,
        oversized        => 0,
        publish_failures => 0,
        published        => 0,
        received         => 0,
        skipped_self     => 0,
        unavailable      => 0,
    };
};

# pg_notify is transactional: PostgreSQL holds the notification until the
# sending transaction commits, and discards it on rollback. That is exactly the
# semantics cache invalidation needs — peers must not drop an entry for a write
# that never landed — so publishing from inside the write transaction is
# correct and deliberate, not an oversight.
sub publish ( $self, $request ) {
    my $payload = $self->_payload($request);
    if ( !$payload ) {
        return 0;
    }

    my $dbh = $self->_dbh;
    if ( !$dbh ) {
        $self->stats->{unavailable} += 1;
        return 0;
    }

    my $sent = eval {
        $dbh->do( 'SELECT pg_notify(?, ?)', undef, $self->channel, $payload );
        return 1;
    };
    if ( !$sent ) {
        $self->stats->{publish_failures} += 1;
        return 0;
    }

    $self->stats->{published} += 1;

    return 1;
}

# Returns the invalidation requests raised by OTHER backends since the last
# call. The caller decides what to do with them, so the bus stays free of any
# cache knowledge and is testable on its own.
sub drain ($self) {
    my $notifications = $self->notifications;
    if ( !$notifications->registered( $self->channel ) ) {
        $notifications->listen_to( $self->channel );
    }

    my $taken = $notifications->take( $self->channel );
    if ( !$taken->{available} ) {
        $self->stats->{unavailable} += 1;
    }

    # A gap means invalidations were lost: raised while this backend was
    # reconnecting, or pushed out of a full queue. Which entries they named
    # is unknown, so all of L1 goes. A refill costs a query; a missed
    # invalidation serves a hidden post until its entry expires.
    if ( $taken->{gap} ) {
        $self->stats->{received} += scalar @{ $taken->{notifications} };
        $self->stats->{gaps}     += 1;
        return [ { clear => 1, keys => [], tags => [] } ];
    }

    my @requests;
    for my $notification ( @{ $taken->{notifications} } ) {
        my $request = $self->_accept($notification);
        if ($request) {
            push @requests, $request;
        }
    }

    return \@requests;
}

sub snapshot ($self) {
    return { %{ $self->stats }, channel => $self->channel };
}

sub _accept ( $self, $notification ) {
    my ( undef, $sender_pid, $payload ) = @{$notification};
    $self->stats->{received} += 1;

    # PostgreSQL delivers a NOTIFY to the sending backend as well. Our own
    # invalidation already ran locally, so replaying it would be wasted work.
    my $own_pid = $self->notifications->backend_pid;
    if ( defined $sender_pid && defined $own_pid && $sender_pid eq $own_pid ) {
        $self->stats->{skipped_self} += 1;
        return;
    }

    my $decoded = eval { return $self->codec->decode( $payload // q{} ) };
    if ( ref $decoded ne 'HASH' ) {
        return;
    }

    $self->stats->{applied} += 1;

    return {
        clear => $decoded->{clear} ? 1 : 0,
        keys  => _list( $decoded->{keys} ),
        tags  => _list( $decoded->{tags} ),
    };
}

sub _payload ( $self, $request ) {
    if ( $request->{clear} ) {
        return $self->_clear_payload;
    }

    my $keys = _list( $request->{keys} );
    my $tags = _list( $request->{tags} );
    if ( !@{$keys} && !@{$tags} ) {
        return;
    }

    my $payload = $self->codec->encode( { keys => $keys, tags => $tags } );
    if ( length $payload > $MAX_PAYLOAD_BYTES ) {
        $self->stats->{oversized} += 1;
        return $self->_clear_payload;
    }

    return $payload;
}

sub _clear_payload ($self) {
    return $self->codec->encode(
        {
            clear => JSON::MaybeXS::true(),
            keys  => [],
            tags  => [],
        }
    );
}

sub _dbh ($self) {
    my $schema = $self->schema;
    if ( !$schema || !$schema->can('storage') ) {
        return;
    }

    my $storage = eval { return $schema->storage };
    if ( !$storage || !$storage->can('dbh') ) {
        return;
    }

    return eval { return $storage->dbh };
}

sub _list ($value) {
    return []       if !defined $value;
    return [$value] if ref $value ne 'ARRAY';

    return [ grep { defined && length } @{$value} ];
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::CacheInvalidationBus - Cross-process cache
invalidation over PostgreSQL LISTEN/NOTIFY.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $bus = GPForum::Service::Operations::CacheInvalidationBus->new(
        schema => $schema );

    $bus->publish( { tags => ['thread:123'] } );

    for my $request ( @{ $bus->drain } ) {
        $cache->invalidate_tag($_) for @{ $request->{tags} };
    }

=head1 DESCRIPTION

A process-local cache layer is invisible to its siblings. Under Hypnotoad every
worker holds its own L1, so an invalidation raised in one worker leaves the
others serving the old entry until it expires — long enough for a hidden post
to stay readable after a moderator removed it.

This bus closes that gap with PostgreSQL's own pub/sub rather than a new piece
of infrastructure. Publishing is transactional, because C<pg_notify> holds the
message until the sending transaction commits and drops it on rollback, so
peers never invalidate for a write that did not land. Draining reads this
channel's share of the process's notification queue
(L<GPForum::Infrastructure::PgNotifications>), which the realtime listener
reads too; the sending backend's PID identifies our own notifications so they
are not replayed.

When the queue reports a gap -- the backend was replaced and its LISTEN
re-issued, or the queue overflowed -- the invalidations in between are gone,
so C<drain> returns one clear request instead.

The bus carries invalidation intent only. It holds no cache and applies
nothing; the caller decides what a request means.

=head1 SUBROUTINES/METHODS

=head2 publish

Broadcasts an invalidation for the given C<keys> and C<tags>. Returns true when
the notification was issued. A batch whose payload would exceed PostgreSQL's
8000-byte NOTIFY limit degrades to a clear request rather than being truncated.

=head2 drain

Returns an arrayref of C<{ clear, keys, tags }> requests raised by other
backends since the last call, or a single clear request after a gap. The first
call issues the LISTEN. Returns nothing while a transaction is open, because
PostgreSQL does not deliver notices mid-transaction.

=head2 snapshot

Counters plus the channel name, for the operations metrics surface.

=head1 DIAGNOSTICS

Never throws. A missing schema, an unreachable handle and a malformed payload
are counted in C<stats> and degrade to no invalidation rather than to an
exception on a read path; a failed LISTEN is counted by the queue.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the application schema's database handle, through the notification
queue Bootstrap shares with the realtime listener. The channel defaults to
C<gpforum_cache_invalidation>.

=head1 DEPENDENCIES

L<Mojo::Base>, L<JSON::MaybeXS>, L<Const::Fast>,
L<GPForum::Infrastructure::PgNotifications>.

=head1 INCOMPATIBILITIES

Requires PostgreSQL LISTEN/NOTIFY. Degrades to no cross-process invalidation on
a handle that does not provide it.

=head1 BUGS AND LIMITATIONS

Notifications raised while this process has a transaction open are read on the
next drain outside it, so a worker's own read path can lag an invalidation by
one request. Each drain costs one round trip: the handle is pinged when it is
fetched.

=head1 AUTHOR

Giacomo Picchiarelli

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Giacomo Picchiarelli. BSD-3-Clause.

=cut
