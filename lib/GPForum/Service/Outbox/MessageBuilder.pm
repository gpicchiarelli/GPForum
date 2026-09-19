package GPForum::Service::Outbox::MessageBuilder;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Domain::EventEnvelope;

our $VERSION = '0.001';

const my $EVENT_QUEUE => 'events';
const my $EVENT_JOB   => 'domain_event.dispatch';

has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has envelope => sub { return GPForum::Domain::EventEnvelope->new; };

sub for_event {
    my ( $self, $event ) = @_;

    return {
        outbox_id       => $self->id_service->uuid,
        event_id        => $event->{event_id},
        queue           => $EVENT_QUEUE,
        job_type        => $EVENT_JOB,
        idempotency_key => _idempotency_key($event),
        payload         => $self->envelope->transport_payload($event),
        status          => 'pending',
    };
}

sub _idempotency_key {
    my ($event) = @_;

    return join q{:}, 'outbox', $event->{event_type}, $event->{event_id};
}

1;
