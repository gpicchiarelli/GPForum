# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::OutboxEventMapper;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Jobs::EventPayload;
use GPForum::Service::Realtime::EventEnvelope;
use GPForum::Service::Realtime::NotificationBadgeReader;

our $VERSION = '0.001';

const my $THREAD_CREATED              => 'thread.created';
const my $THREAD_UPDATED              => 'thread.updated';
const my $THREAD_DELETED              => 'thread.deleted';
const my $THREAD_MOVED                => 'thread.moved';
const my $THREAD_HIDDEN               => 'thread.hidden';
const my $THREAD_RESTORED             => 'thread.restored';
const my $THREAD_UNDELETED            => 'thread.undeleted';
const my $POST_CREATED                => 'post.created';
const my $POST_UPDATED                => 'post.updated';
const my $POST_DELETED                => 'post.deleted';
const my $POST_UNDELETED              => 'post.undeleted';
const my $THREAD_UPDATE               => 'thread.update';
const my $NOTIFICATION_BADGE          => 'notification.badge';
const my $MODERATION_QUEUE_INVALIDATE => 'moderation.queue.invalidate';

const my %THREAD_CONTENT => (
    $THREAD_CREATED   => 1,
    $THREAD_DELETED   => 1,
    $THREAD_HIDDEN    => 1,
    $THREAD_MOVED     => 1,
    $THREAD_RESTORED  => 1,
    $THREAD_UNDELETED => 1,
    $THREAD_UPDATED   => 1,
);

const my %POST_CONTENT => (
    $POST_CREATED   => 1,
    $POST_DELETED   => 1,
    $POST_UNDELETED => 1,
    $POST_UPDATED   => 1,
);

has payload_contract => sub { return GPForum::Jobs::EventPayload->new; };
has schema           => undef;
has notification_badge_reader => undef;
has readability               => undef;
has realtime_contract =>
  sub { return GPForum::Service::Realtime::EventEnvelope->new; };

sub events_for_payload ( $self, $raw_payload, $handler_results = undef ) {
    my $payload = $self->payload_contract->normalize($raw_payload);
    my @events;

    my $domain_event = $self->_domain_realtime_event_for($payload);
    if ($domain_event) {
        push @events, $domain_event;
    }
    push @events,
      $self->_notification_badge_events( $payload, $handler_results || [] );

    return @events;
}

sub _domain_realtime_event_for ( $self, $payload ) {
    my $event_type = $payload->{event_type} || q{};
    return $self->_post_created_event($payload)
      if _post_content_event($event_type);
    return $self->_thread_created_event($payload)
      if _thread_content_event($event_type);
    return $self->_moderation_event($payload)
      if $event_type =~ /\A moderation[.] | \A report[.] /msx;

    my $undefined;
    return $undefined;
}

sub _post_content_event ($event_type) {
    if ( !defined $event_type ) {
        return 0;
    }

    return exists $POST_CONTENT{$event_type} ? 1 : 0;
}

sub _thread_content_event ($event_type) {
    if ( !defined $event_type ) {
        return 0;
    }

    return exists $THREAD_CONTENT{$event_type} ? 1 : 0;
}

sub _post_created_event ( $self, $payload ) {
    my $thread_id = _event_value( $payload, 'thread_id' );
    my $undefined;
    return $undefined if !defined $thread_id;

    return $self->realtime_contract->build(
        event_id       => $payload->{event_id},
        type           => $THREAD_UPDATE,
        aggregate_type => 'thread',
        aggregate_id   => $thread_id,
        actor_id       => $payload->{actor_id},
        correlation_id => $payload->{correlation_id},
        causation_id   => $payload->{event_id},
        payload        => {
            post_id   => $payload->{aggregate_id},
            thread_id => $thread_id,
        },
        metadata => { source_event_type => $payload->{event_type} },
    );
}

sub _thread_created_event ( $self, $payload ) {
    return $self->realtime_contract->build(
        event_id       => $payload->{event_id},
        type           => $THREAD_UPDATE,
        aggregate_type => 'thread',
        aggregate_id   => $payload->{aggregate_id},
        actor_id       => $payload->{actor_id},
        correlation_id => $payload->{correlation_id},
        causation_id   => $payload->{event_id},
        payload        => { thread_id         => $payload->{aggregate_id} },
        metadata       => { source_event_type => $payload->{event_type} },
    );
}

sub _moderation_event ( $self, $payload ) {
    return $self->realtime_contract->build(
        event_id       => $payload->{event_id},
        type           => $MODERATION_QUEUE_INVALIDATE,
        aggregate_type => $payload->{aggregate_type},
        aggregate_id   => $payload->{aggregate_id},
        actor_id       => $payload->{actor_id},
        correlation_id => $payload->{correlation_id},
        causation_id   => $payload->{event_id},
        payload        => { source_event_type => $payload->{event_type} },
        metadata       => { source_event_type => $payload->{event_type} },
    );
}

sub _notification_badge_events ( $self, $payload, $handler_results ) {
    my %unread_count_for = _notification_badges($handler_results);
    if ( !%unread_count_for ) {
        %unread_count_for = $self->_notification_badges_from_source($payload);
    }

    my @user_ids = sort keys %unread_count_for;
    my @events;

    for my $user_id (@user_ids) {
        push @events,
          $self->_notification_badge_event( $payload, $user_id,
            $unread_count_for{$user_id} );
    }

    return @events;
}

sub _notification_badges_from_source ( $self, $payload ) {
    my $reader = $self->_notification_badge_reader;

    # The caller assigns this to a hash, so the no-reader case must yield an
    # empty list. Returning a single undef would make the assignment odd and
    # silently pair a user id with nothing.
    return () if !$reader;

    return $reader->badges_for_payload($payload);
}

sub _notification_badge_reader ($self) {
    return $self->notification_badge_reader if $self->notification_badge_reader;
    my $undefined;
    return $undefined if !$self->schema;

    return GPForum::Service::Realtime::NotificationBadgeReader->new(
        readability => $self->readability,
        schema      => $self->schema,
    );
}

sub _notification_badge_event ( $self, $payload, $user_id, $count ) {
    return $self->realtime_contract->build(
        event_id =>
          join( q{:}, $payload->{event_id}, $NOTIFICATION_BADGE, $user_id ),
        type           => $NOTIFICATION_BADGE,
        aggregate_type => 'user',
        aggregate_id   => $user_id,
        actor_id       => $payload->{actor_id},
        correlation_id => $payload->{correlation_id},
        causation_id   => $payload->{event_id},
        payload        => { unread_count      => $count },
        metadata       => { source_event_type => $payload->{event_type} },
    );
}

sub _notification_badges ($handler_results) {
    my %unread_count_for;
    for my $fanout ( _fanouts($handler_results) ) {
        for my $delivery ( @{ $fanout->{created} || [] } ) {
            my $user_id = _notification_user_id($delivery);
            next if !defined $user_id;

            $unread_count_for{$user_id} = $delivery->{unread_count};
        }
    }

    return %unread_count_for;
}

sub _fanouts ($handler_results) {
    return map { $_->{fanout} }
      grep { ref $_ eq 'HASH' && ref $_->{fanout} eq 'HASH' }
      @{$handler_results};
}

sub _notification_user_id ($delivery) {
    my $undefined;
    return $undefined if ref $delivery ne 'HASH';
    return $undefined if !defined $delivery->{unread_count};

    my $notification = $delivery->{notification} || {};

    return $notification->{recipient_user_id};
}

sub _event_value ( $event, $name ) {
    return $event->{$name} if defined $event->{$name};

    my $payload = $event->{domain_payload} || {};

    return $payload->{$name};
}

1;
