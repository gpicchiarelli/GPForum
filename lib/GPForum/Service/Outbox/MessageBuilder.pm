package GPForum::Service::Outbox::MessageBuilder;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Id;

our $VERSION = '0.001';

const my $EVENT_QUEUE => 'events';
const my $EVENT_JOB   => 'domain_event.dispatch';

has id_service => sub { return GPForum::Service::Id->new; };

sub for_event {
    my ( $self, $event ) = @_;

    return {
        outbox_id       => $self->id_service->uuid,
        event_id        => $event->{event_id},
        queue           => $EVENT_QUEUE,
        job_type        => $EVENT_JOB,
        idempotency_key => _idempotency_key($event),
        payload         => _payload($event),
        status          => 'pending',
    };
}

sub _idempotency_key {
    my ($event) = @_;

    return join q{:}, 'outbox', $event->{event_type}, $event->{event_id};
}

sub _payload {
    my ($event) = @_;

    return {
        event_id          => $event->{event_id},
        event_type        => $event->{event_type},
        aggregate_type    => $event->{aggregate_type},
        aggregate_id      => $event->{aggregate_id},
        aggregate_version => $event->{aggregate_version},
        actor_id          => $event->{actor_id},
        correlation_id    => $event->{correlation_id},
        causation_id      => $event->{causation_id},
        schema_version    => $event->{schema_version},
    };
}

1;
