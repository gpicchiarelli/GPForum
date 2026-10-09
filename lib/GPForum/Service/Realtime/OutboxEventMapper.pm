# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::OutboxEventMapper;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

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

    return undef;
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
    return undef if !defined $thread_id;

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

__END__

=head1 NAME

GPForum::Service::Realtime::OutboxEventMapper - The realtime hint a domain event becomes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $mapper = GPForum::Service::Realtime::OutboxEventMapper->new;
    my @events = $mapper->events_for_payload( $outbox_message_payload );
    # () or ( { type => 'thread.update', ... } )

=head1 DESCRIPTION

Maps an outbox domain event to at most one realtime frame, built with
L<GPForum::Service::Realtime::EventEnvelope>. The frame is a hint: it
carries ids only and is idempotent, so a duplicate or a late one is
harmless (F<docs/realtime.md>). The worker's
transport (L<GPForum::Service::Outbox::DomainEventTransport>) sends it
once per event, and L<GPForum::Service::Realtime::PgListener>'s outbox
backstop maps the messages it polls the same way.

=over 4

=item *

C<post.created>, C<post.updated>, C<post.deleted> and C<post.undeleted>
become C<thread.update> on the post's thread, with
C<< payload => { post_id, thread_id } >>. The thread id is read from the
event, or from its domain payload; without one there is no frame.

=item *

C<thread.created>, C<thread.updated>, C<thread.deleted>, C<thread.moved>,
C<thread.hidden>, C<thread.restored> and C<thread.undeleted> become
C<thread.update> on the thread, with C<< payload => { thread_id } >>.

=item *

Any C<moderation.*> or C<report.*> event becomes
C<moderation.queue.invalidate> on the event's aggregate, with the source
event type as its payload.

=item *

Every other event maps to nothing.

=back

Each frame keeps the domain event's C<event_id>, C<actor_id> and
C<correlation_id>, takes the event id as its C<causation_id>, and records
the source event type in C<metadata>. Notification badges are not mapped:
the notification dispatcher sends each count itself when it changes, and
mapping them here as well sent every badge twice.

The attributes are C<payload_contract> (a L<GPForum::Jobs::EventPayload>)
and C<realtime_contract> (a L<GPForum::Service::Realtime::EventEnvelope>).

=head1 SUBROUTINES/METHODS

=head2 events_for_payload

Takes an outbox message payload, normalized first with the C<normalize>
method of L<GPForum::Jobs::EventPayload> (anything but a hash reference
becomes an empty one). Returns a list of zero or one realtime frame
hash references. The frame is built, not validated.

=head1 DIAGNOSTICS

None. An event it does not map, or a post event without a thread id,
yields an empty list.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, L<GPForum::Jobs::EventPayload>,
L<GPForum::Service::Realtime::EventEnvelope>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
