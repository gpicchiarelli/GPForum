package GPForum::Service::Outbox::DomainEventTransport;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Jobs::EventPayload;
use GPForum::Service::Realtime::EventEnvelope;

our $VERSION = '0.001';

has handlers         => sub { return []; };
has payload_contract => sub { return GPForum::Jobs::EventPayload->new; };
has realtime_contract =>
  sub { return GPForum::Service::Realtime::EventEnvelope->new; };
has realtime_notifier => undef;

sub dispatch {
    my ( $self, $message ) = @_;

    my $payload =
      $self->payload_contract->normalize( $message->get_column('payload') );
    my @results;

    for my $handler ( @{ $self->handlers } ) {
        next if !$handler->supports($payload);

        push @results, $handler->handle($payload);
    }
    my $realtime = $self->_notify_realtime($payload);

    return {
        ok       => 1,
        handlers => scalar @results,
        results  => \@results,
        ( $realtime ? ( realtime => $realtime ) : () ),
    };
}

sub _notify_realtime {
    my ( $self, $payload ) = @_;

    return if !$self->realtime_notifier;

    my $event = $self->_realtime_event_for($payload);
    return if !$event;

    return $self->realtime_notifier->notify($event);
}

sub _realtime_event_for {
    my ( $self, $payload ) = @_;

    my $thread_id  = _event_value( $payload, 'thread_id' );
    my $event_type = $payload->{event_type} || q{};
    if ( $event_type eq 'post.created' && defined $thread_id ) {
        return $self->realtime_contract->build(
            event_id       => $payload->{event_id},
            type           => 'thread.update',
            aggregate_type => 'thread',
            aggregate_id   => $thread_id,
            actor_id       => $payload->{actor_id},
            correlation_id => $payload->{correlation_id},
            causation_id   => $payload->{event_id},
            payload        => {
                post_id   => $payload->{aggregate_id},
                thread_id => $thread_id,
            },
            metadata => { source_event_type => $event_type },
        );
    }

    if ( $event_type eq 'thread.created' ) {
        return $self->realtime_contract->build(
            event_id       => $payload->{event_id},
            type           => 'thread.update',
            aggregate_type => 'thread',
            aggregate_id   => $payload->{aggregate_id},
            actor_id       => $payload->{actor_id},
            correlation_id => $payload->{correlation_id},
            causation_id   => $payload->{event_id},
            payload        => { thread_id         => $payload->{aggregate_id} },
            metadata       => { source_event_type => $event_type },
        );
    }

    return if $event_type !~ /\A moderation[.]/msx;

    return $self->realtime_contract->build(
        event_id       => $payload->{event_id},
        type           => 'moderation.queue.invalidate',
        aggregate_type => $payload->{aggregate_type},
        aggregate_id   => $payload->{aggregate_id},
        actor_id       => $payload->{actor_id},
        correlation_id => $payload->{correlation_id},
        causation_id   => $payload->{event_id},
        payload        => { source_event_type => $event_type },
        metadata       => { source_event_type => $event_type },
    );
}

sub _event_value {
    my ( $event, $name ) = @_;

    return $event->{$name} if defined $event->{$name};

    my $payload = $event->{domain_payload} || {};

    return $payload->{$name};
}

1;
