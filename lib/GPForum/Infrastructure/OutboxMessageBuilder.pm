# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Infrastructure::OutboxMessageBuilder;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Domain::EventEnvelope;

our $VERSION = '0.001';

const my $EVENT_QUEUE => 'events';
const my $EVENT_JOB   => 'domain_event.dispatch';

has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has envelope => sub { return GPForum::Domain::EventEnvelope->new; };

sub for_event ( $self, $event, $extras = undef ) {
    return _with_payload_extras(
        {
            outbox_id       => $self->id_service->uuid,
            event_id        => $event->{event_id},
            queue           => $EVENT_QUEUE,
            job_type        => $EVENT_JOB,
            idempotency_key => idempotency_key_for($event),
            payload         => $self->envelope->transport_payload($event),
            status          => 'pending',
        },
        $extras
    );
}

# The message that does a dead letter's work again: the envelope the failed
# message carried, as the same job, under the replay's own idempotency key.
# The envelope names its event, so the replay needs nothing from the failed
# message, which retention may already have purged.
sub for_replay ( $self, $idempotency_key, $envelope ) {
    return {
        outbox_id       => $self->id_service->uuid,
        event_id        => $envelope->{event_id},
        queue           => $EVENT_QUEUE,
        job_type        => $EVENT_JOB,
        idempotency_key => $idempotency_key,
        payload         => $envelope,
        status          => 'pending',
    };
}

sub _with_payload_extras ( $row, $extras ) {
    if ( !$extras ) {
        return $row;
    }

    $row->{payload} = { %{ $row->{payload} }, %{$extras} };

    return $row;
}

sub idempotency_key_for ($event) {
    return join q{:}, 'outbox', $event->{event_type}, $event->{event_id};
}

1;
