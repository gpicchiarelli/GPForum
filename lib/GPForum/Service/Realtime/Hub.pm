# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::Hub;

use Const::Fast;
use List::Util qw(uniq);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Service::Realtime::ChannelAuthorizer;
use GPForum::Service::Realtime::ConnectionRegistry;
use GPForum::Service::Realtime::EventEnvelope;

our $VERSION = '0.001';

const my $FALLBACK_POLL_SECONDS => 30;
const my $THREAD_UPDATE         => 'thread.update';
const my $NOTIFICATION_BADGE    => 'notification.badge';
const my $NOTIFICATIONS         => 'notifications';
const my $MODERATION_INVALIDATE => 'moderation.queue.invalidate';
const my %CHANNEL_TYPE_FOR_EVENT => (
    $THREAD_UPDATE      => 'thread',
    $NOTIFICATION_BADGE => $NOTIFICATIONS,
);

has authorizer =>
  sub { return GPForum::Service::Realtime::ChannelAuthorizer->new; };

# Answers unread_count_for_user: the notification dispatcher, whose count is
# the inbox's own -- readable sources only, capped (ADR 0102). Badge
# snapshots need it; without one none are sent.
has badge_counter => undef;    # optional: without one no badge is sent
has event_contract =>
  sub { return GPForum::Service::Realtime::EventEnvelope->new; };
has registry =>
  sub { return GPForum::Service::Realtime::ConnectionRegistry->new; };

# ADR 0102: who may read a thread is asked again at every broadcast on its
# channel. Without it a subscriber kept receiving the thread's activity after
# its category turned private, their grant was revoked or they were
# suspended.
has readability => undef;    # optional: readers go unfiltered without it
has stats       => sub {
    return {
        badge_snapshots    => 0,
        broadcast          => 0,
        broadcast_failures => 0,
        broadcasts         => 0,
        delivered          => 0,
        failed             => 0,
        malformed          => 0,
        malformed_events   => 0,
    };
};

sub register_connection ( $self, $connection_id, $actor, $connection ) {
    return $self->registry->register( $connection_id, $actor, $connection );
}

sub disconnect ( $self, $connection_id ) {
    return $self->registry->unregister($connection_id);
}

sub subscribe ( $self, $request ) {
    my $authorization =
      $self->authorizer->authorize( $request->{actor}, $request->{channel},
        $request->{context} || {},
      );
    return $authorization if !$authorization->{ok};

    my $subscription = $self->registry->subscribe( $request->{connection_id},
        $request->{channel} );
    return $subscription if !$subscription->{ok};

    return {
        ok      => 1,
        channel => $request->{channel},
        reason  => $authorization->{reason},
    };
}

sub broadcast ( $self, $channel, $payload ) {
    my @subscribers = $self->_post_readers( $payload,
        $self->_readers( $channel, $self->registry->subscribers($channel) ) );
    my $delivered = 0;
    my $failed    = 0;
    $self->stats->{broadcast}  += 1;
    $self->stats->{broadcasts} += 1;

    for my $subscriber (@subscribers) {
        my $sent = _send_json( $subscriber->{connection}, $payload );
        if ($sent) {
            $delivered++;
        }
        else {
            $failed++;
        }
    }
    $self->stats->{delivered}          += $delivered;
    $self->stats->{failed}             += $failed;
    $self->stats->{broadcast_failures} += $failed;

    return {
        ok        => 1,
        channel   => $channel,
        delivered => $delivered,
        failed    => $failed,
    };
}

# The connection's user's unread count, sent to that connection alone. A
# badge carries an absolute count, so one snapshot heals whatever a socket
# missed: a subscriber that has just (re)connected, possibly to another node,
# or every subscriber after this process lost notifications in a gap.
sub send_badge_snapshot ( $self, $connection_id ) {
    my $row     = $self->registry->connection($connection_id);
    my $user_id = $row ? _user_id( $row->{actor} ) : undef;
    return { ok => 0, reason => 'connection_not_found' } if !defined $user_id;

    return $self->_send_badge( $row, $user_id, $self->_unread_count($user_id) );
}

# Returns how many snapshots were sent. Each user's count is read once,
# however many of their sockets this process holds: a gap follows a
# reconnect, when every process of every node resends at the same moment to
# a database that has just come back.
sub resend_badge_snapshots ($self) {
    my %count_of;
    my $sent = 0;
    for my $row ( $self->registry->subscribers_of_family($NOTIFICATIONS) ) {
        my $user_id = _user_id( $row->{actor} );
        next if !defined $user_id;

        if ( !exists $count_of{$user_id} ) {
            $count_of{$user_id} = $self->_unread_count($user_id);
        }
        my $snapshot =
          $self->_send_badge( $row, $user_id, $count_of{$user_id} );
        if ( $snapshot->{ok} ) {
            $sent++;
        }
    }

    return $sent;
}

# Undef when there is no counter or it failed.
sub _unread_count ( $self, $user_id ) {
    return undef if !$self->badge_counter;

    my $count;
    try {
        $count = $self->badge_counter->unread_count_for_user($user_id);
    }
    catch ($error) {
        return undef;
    };

    return $count;
}

sub _send_badge ( $self, $row, $user_id, $count ) {
    return { ok => 0, reason => 'badge_unavailable' } if !defined $count;

    my $sent = _send_json( $row->{connection},
        $self->event_contract->notification_badge( $user_id, $count ) );
    $self->stats->{badge_snapshots} += 1;

    return { ok => $sent ? 1 : 0, unread_count => $count };
}

sub connection_count ($self) {
    return $self->registry->count;
}

sub broadcast_event ( $self, $event ) {
    my $rejection = $self->_event_rejection($event);
    return $rejection if $rejection;

    my @channels = _channels_for_event($event);
    return _empty_broadcast_event_summary() if !@channels;

    return $self->_broadcast_to_channels( $event, @channels );
}

sub _event_rejection ( $self, $event ) {
    my $validation = $self->event_contract->validate($event);
    return undef if $validation->{ok};

    $self->stats->{malformed}        += 1;
    $self->stats->{malformed_events} += 1;

    return { ok => 0, reason => $validation->{reason} };
}

sub _broadcast_to_channels ( $self, $event, @channels ) {
    my %summary = (
        ok        => 1,
        delivered => 0,
        failed    => 0,
        channels  => \@channels,
    );

    for my $channel (@channels) {
        my $result = $self->broadcast( $channel, $event );
        $summary{delivered} += $result->{delivered} || 0;
        $summary{failed}    += $result->{failed}    || 0;
    }

    return \%summary;
}

sub _empty_broadcast_event_summary {
    return { ok => 1, delivered => 0, failed => 0, channels => [] };
}

sub fallback_state ($self) {
    return {
        realtime_required  => 0,
        poll_after_seconds => $FALLBACK_POLL_SECONDS,
        endpoints          => {
            notifications => '/notifications',
            thread        => '/thread/:thread_id',
        },
    };
}

sub snapshot ($self) {
    return { %{ $self->registry->snapshot }, %{ $self->stats }, };
}

# The subscribers who may read a thread channel's thread now: one query for
# a public thread, a viewer per subscriber otherwise. The others are sent
# nothing but stay subscribed: every broadcast asks again, so a subscriber
# who regains access -- a thread restored, a grant given back -- resumes,
# and one who lost it receives nothing. Dropping them for good left every
# open page deaf after a thread was hidden and restored. Other channels were
# authorised to their own user or permission when subscribed.
sub _readers ( $self, $channel, @subscribers ) {
    my $parsed =
      GPForum::Service::Realtime::ChannelAuthorizer::parse_channel($channel);
    return @subscribers
      if !$self->readability
      || !@subscribers
      || !$parsed
      || $parsed->{type} ne 'thread';

    return $self->_readers_of( 'thread', $parsed->{resource_id}, @subscribers );
}

# An event about one post names the post and its author, so only readers of
# that post receive it: a private reply in a public thread is not announced
# to the thread's other subscribers.
sub _post_readers ( $self, $event, @subscribers ) {
    my $post_id =
      ref $event eq 'HASH' && ref $event->{payload} eq 'HASH'
      ? $event->{payload}{post_id}
      : undef;
    return @subscribers
      if !$self->readability || !defined $post_id || !@subscribers;

    return $self->_readers_of( 'post', $post_id, @subscribers );
}

sub _readers_of ( $self, $type, $id, @subscribers ) {
    my %user_of =
      map { $_->{connection_id} => _user_id( $_->{actor} ) // q{} }
      @subscribers;
    my %readable = map { $_ => 1 }
      $self->readability->readers_of( $type, $id, uniq values %user_of );

    return grep { $readable{ $user_of{ $_->{connection_id} } } } @subscribers;
}

sub _user_id ($actor) {
    return ref $actor eq 'HASH' ? $actor->{user_id} : $actor;
}

sub _send_json ( $connection, $payload ) {
    return undef if !$connection;

    my $sent;
    try {
        $sent = $connection->send( { json => $payload } );
    }
    catch ($error) {
        return undef;
    };

    return $sent;
}

sub _channel ( $type, $id ) {
    return join q{:}, $type, $id;
}

sub _channels_for_event ($event) {
    my $event_type = $event->{type} || q{};
    if ( exists $CHANNEL_TYPE_FOR_EVENT{$event_type} ) {
        my $channel_type = $CHANNEL_TYPE_FOR_EVENT{$event_type};
        return _aggregate_channel( $channel_type, $event );
    }

    return _moderation_channels($event);
}

sub _aggregate_channel ( $channel_type, $event ) {
    return if !defined $event->{aggregate_id};

    return ( _channel( $channel_type, $event->{aggregate_id} ) );
}

sub _moderation_channels ($event) {
    if ( ( $event->{type} || q{} ) eq $MODERATION_INVALIDATE ) {
        return ('moderation:queue');
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Realtime::Hub - Holds this process's realtime sockets and subscriptions and broadcasts events to them.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $hub = GPForum::Service::Realtime::Hub->new(
        authorizer    => $channel_authorizer,
        badge_counter => $notification_dispatcher,
        readability   => GPForum::Service::Forum::Readability->new(
            schema => $schema,
        ),
    );
    $hub->register_connection( $connection_id, { user_id => $user_id },
        $websocket );
    my $subscribed = $hub->subscribe(
        {
            actor         => { user_id => $user_id },
            channel       => "notifications:$user_id",
            connection_id => $connection_id,
            context       => { transport => 'websocket' },
        }
    );
    $hub->send_badge_snapshot($connection_id);
    my $summary = $hub->broadcast_event($event);
    $hub->disconnect($connection_id);

=head1 DESCRIPTION

One hub per process, kept by the C<gp_realtime_hub> helper. The websocket
controller registers each socket and its subscriptions here; the PostgreSQL
listener hands it every event that arrives from any node. Connections and
subscriptions live in the C<registry>, a
L<GPForum::Service::Realtime::ConnectionRegistry>, so they are local to the
process.

A subscription is granted by the C<authorizer>. Access to a thread is asked
again at every broadcast (ADR 0102): when C<readability> is set, a
C<thread:> channel's subscribers are narrowed to those who may read the
thread now, and an event whose payload names a C<post_id> to those who may
read that post. A subscriber filtered out stays subscribed and receives
the thread again once access comes back.

An event goes to channels by its type: C<thread.update> to
C<< thread:<aggregate_id> >>, C<notification.badge> to
C<< notifications:<aggregate_id> >>, C<moderation.queue.invalidate> to
C<moderation:queue>. Any other type goes nowhere.

Badges carry an absolute unread count, so one snapshot corrects whatever a
socket missed. The count comes from C<badge_counter> (the notification
dispatcher's C<unread_count_for_user>); without one, no badge is sent.

=head1 SUBROUTINES/METHODS

=head2 register_connection

Takes a connection id, an actor (a hash reference with C<user_id>, or the
user id) and the connection object, which must have a C<send> method.
Returns the registry's row, or undef when the user already holds the
registry's per-process maximum of sockets.

=head2 disconnect

Takes a connection id. Removes it and its subscriptions; returns the
removed row, or undef when there was none.

=head2 subscribe

Takes a hash reference with C<actor>, C<channel>, C<connection_id> and an
optional C<context>. Returns the authorizer's refusal when it refuses, the
registry's refusal (C<connection_not_found> or
C<subscription_quota_exceeded>) when that fails, and otherwise
C<< { ok => 1, channel, reason } >> with the authorizer's reason.

=head2 broadcast

Takes a channel name and the event to send, and sends it as JSON to every
subscriber of the channel left after the readability filters. Returns
C<< { ok => 1, channel, delivered, failed } >>; a send that dies or returns
false counts as failed and is not raised.

=head2 send_badge_snapshot

Takes a connection id and sends that connection its user's unread count as
a C<notification.badge> event. Returns
C<< { ok => 0, reason => 'connection_not_found' } >> when there is no such
connection or it has no user, C<< { ok => 0, reason => 'badge_unavailable' } >>
when there is no C<badge_counter> or it died, and otherwise
C<< { ok, unread_count } >> with C<ok> 0 when the send failed.

=head2 resend_badge_snapshots

Takes no arguments. Sends a badge to every connection subscribed to at
least one C<notifications:> channel, reading each user's count once
however many sockets they hold. Returns the number of badges sent. The
listener calls it after a gap in notifications.

=head2 connection_count

Returns the number of connections registered in this process.

=head2 broadcast_event

Takes an event. Returns the C<event_contract>'s refusal
C<< { ok => 0, reason } >> when it does not validate; otherwise
C<< { ok => 1, delivered, failed, channels } >>, the counts summed over the
channels the event maps to, with an empty C<channels> when it maps to
none.

=head2 fallback_state

Returns what a client without a socket should do: C<realtime_required> 0,
C<poll_after_seconds> 30, and the C<notifications> and C<thread> endpoints
to poll.

=head2 snapshot

Returns the registry's snapshot (C<connections>, C<subscriptions> and the
two limits) merged with the hub's counters: C<badge_snapshots>,
C<broadcast> and C<broadcasts>, C<delivered>, C<failed> and
C<broadcast_failures>, C<malformed> and C<malformed_events>. The paired
counters are kept equal.

=head1 DIAGNOSTICS

None raised. Failed sends and badge counts are returned and counted. An
exception from the authorizer or from C<readability> propagates.

=head1 CONFIGURATION AND ENVIRONMENT

None read directly. The registry's per-user and per-connection limits are
its own attributes.

=head1 DEPENDENCIES

L<Const::Fast>, L<List::Util>, L<Mojo::Base>,
L<GPForum::Service::Realtime::ChannelAuthorizer>,
L<GPForum::Service::Realtime::ConnectionRegistry>,
L<GPForum::Service::Realtime::EventEnvelope>;
L<GPForum::Service::Forum::Readability> (passed in as C<readability>).

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The state is per process; a node reaches the sockets of another only
through the PostgreSQL listener. Without C<readability>, thread and post
events go to every subscriber of the channel.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
