# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::OutboxEventMapper;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Jobs::EventPayload;
use GPForum::Service::Realtime::EventEnvelope;

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
has realtime_contract =>
  sub { return GPForum::Service::Realtime::EventEnvelope->new; };

# The id-only hint a domain event becomes. Badges are not mapped here: the
# notification dispatcher NOTIFYs each count itself when it changes, from a
# web request or from the worker's fanout alike, and a socket that missed one
# gets a snapshot. Mapping them here as well sent every badge twice, and the
# backstop's rebuild from the notification tables cost queries in every
# worker for every polled post.
sub events_for_payload ( $self, $raw_payload ) {
    my $payload      = $self->payload_contract->normalize($raw_payload);
    my $domain_event = $self->_domain_realtime_event_for($payload);

    return $domain_event ? ($domain_event) : ();
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

sub _event_value ( $event, $name ) {
    return $event->{$name} if defined $event->{$name};

    my $payload = $event->{domain_payload} || {};

    return $payload->{$name};
}

1;
