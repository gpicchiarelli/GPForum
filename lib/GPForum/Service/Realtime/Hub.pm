# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::Hub;

use strict;
use warnings;

use Const::Fast;
use List::Util qw(uniq);
use Mojo::Base -base, -signatures;

use GPForum::Service::Realtime::ChannelAuthorizer;
use GPForum::Service::Realtime::ConnectionRegistry;
use GPForum::Service::Realtime::EventEnvelope;

our $VERSION = '0.001';

const my $FALLBACK_POLL_SECONDS => 30;
const my $THREAD_UPDATE         => 'thread.update';
const my $NOTIFICATION_BADGE    => 'notification.badge';
const my $MODERATION_INVALIDATE => 'moderation.queue.invalidate';
const my %CHANNEL_TYPE_FOR_EVENT => (
    $THREAD_UPDATE      => 'thread',
    $NOTIFICATION_BADGE => 'notifications',
);

has authorizer =>
  sub { return GPForum::Service::Realtime::ChannelAuthorizer->new; };
has event_contract =>
  sub { return GPForum::Service::Realtime::EventEnvelope->new; };
has registry =>
  sub { return GPForum::Service::Realtime::ConnectionRegistry->new; };

# ADR 0102: who may read a thread is asked again at every broadcast on its
# channel. Without it a subscriber kept receiving the thread's activity after
# its category turned private, their grant was revoked or they were
# suspended.
has readability => undef;
has stats       => sub {
    return {
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

sub broadcast_thread_update ( $self, $thread_id, $payload ) {
    my $event = $self->event_contract->build(
        type           => $THREAD_UPDATE,
        aggregate_type => 'thread',
        aggregate_id   => $thread_id,
        payload        => $payload || {},
        metadata       => { channel_type => 'thread' },
    );
    $event->{thread_id} = $thread_id;

    return $self->broadcast( _channel( 'thread', $thread_id ), $event, );
}

sub broadcast_notification_badge ( $self, $user_id, $count ) {
    my $event = $self->event_contract->build(
        type           => $NOTIFICATION_BADGE,
        aggregate_type => 'user',
        aggregate_id   => $user_id,
        payload        => { unread_count => $count },
        metadata       => { channel_type => 'notifications' },
    );
    $event->{user_id}      = $user_id;
    $event->{unread_count} = $count;

    return $self->broadcast( _channel( 'notifications', $user_id ), $event, );
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
    my $undefined;
    return $undefined if $validation->{ok};

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
    my $undefined;
    return $undefined if !$connection;

    return eval { return $connection->send( { json => $payload } ); };
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
