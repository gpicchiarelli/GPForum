# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Domain::EventEnvelope;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $CONTRACT_NAME    => 'gpforum.domain_event';
const my $CONTRACT_VERSION => 1;
const my $DEFAULT_VERSION  => 1;
const my $MIN_VERSION      => 1;

sub record ( $self, %input ) {
    my $schema_version    = _positive_integer( $input{schema_version} );
    my $aggregate_version = _positive_integer( $input{aggregate_version} );
    my $event             = {
        event_id       => _required( event_id   => $input{event_id} ),
        event_type     => _required( event_type => $input{event_type} ),
        schema_version => $schema_version,
        aggregate_type => _required( aggregate_type => $input{aggregate_type} ),
        aggregate_id   => $input{aggregate_id},
        aggregate_version => $aggregate_version,
        actor_id          => $input{actor_id},
        correlation_id => _required( correlation_id => $input{correlation_id} ),
        causation_id   => $input{causation_id},
        idempotency_key => $input{idempotency_key} || $self->idempotency_key(
            event_type   => $input{event_type},
            aggregate_id => $input{aggregate_id},
        ),
        payload  => _hash( $input{payload} ),
        metadata => _metadata(%input),
    };

    $event->{created_at} = $input{timestamp}
      if defined $input{timestamp} && length $input{timestamp};

    return $event;
}

sub transport_payload ( $self, $event ) {
    my $event_metadata = _hash( $event->{metadata} );
    my $metadata       = _metadata(
        %{$event},
        metadata  => $event_metadata,
        timestamp => $event->{created_at} || $event_metadata->{timestamp},
    );
    my $timestamp = $event->{created_at} || $metadata->{timestamp};

    my $payload = {
        aggregate => {
            id      => $event->{aggregate_id},
            type    => $event->{aggregate_type},
            version => $event->{aggregate_version},
        },
        aggregate_id      => $event->{aggregate_id},
        aggregate_type    => $event->{aggregate_type},
        aggregate_version => $event->{aggregate_version},
        actor             => { id => $event->{actor_id} },
        actor_id          => $event->{actor_id},
        causation_id      => $event->{causation_id},
        contract          => $CONTRACT_NAME,
        contract_version  => $CONTRACT_VERSION,
        correlation_id    => $event->{correlation_id},
        domain_payload    => _hash( $event->{payload} ),
        event_id          => $event->{event_id},
        event_type        => $event->{event_type},
        idempotency_key   => $event->{idempotency_key},
        metadata          => $metadata,
        payload           => _hash( $event->{payload} ),
        schema_version    => $event->{schema_version},
        transport         => _transport_metadata($event),
    };

    if ( defined $timestamp && length $timestamp ) {
        $payload->{timestamp}   = $timestamp;
        $payload->{occurred_at} = $timestamp;
    }

    return $payload;
}

sub idempotency_key ( $self, %input ) {
    return join q{:},
      _required( event_type   => $input{event_type} ),
      _required( aggregate_id => $input{aggregate_id} );
}

sub contract_name {
    return $CONTRACT_NAME;
}

sub contract_version {
    return $CONTRACT_VERSION;
}

sub _metadata (%input) {
    my $metadata = _hash( $input{metadata} );
    $metadata->{actor} = {
        id => $input{actor_id},
        ( defined $input{actor_ip} ? ( ip => $input{actor_ip} ) : () ),
    };
    $metadata->{aggregate_id}   = $input{aggregate_id};
    $metadata->{causation_id}   = $input{causation_id};
    $metadata->{correlation_id} = $input{correlation_id};
    $metadata->{event_id}       = $input{event_id};
    $metadata->{timestamp}      = $input{timestamp}
      if defined $input{timestamp} && length $input{timestamp};
    $metadata->{transport} = {
        listen_notify_channel => 'gpforum_domain_events',
        minion_job            => 'domain_event.dispatch',
        stream                => 'gpforum.domain_events',
    };

    return $metadata;
}

sub _transport_metadata ($event) {
    return {
        kafka_topic           => 'gpforum.domain_events',
        listen_notify_channel => 'gpforum_domain_events',
        minion_job            => 'domain_event.dispatch',
        nats_subject          => 'gpforum.domain_events',
        partition_key         => $event->{aggregate_id} || $event->{event_id},
    };
}

sub _hash ($value) {
    return { %{$value} } if ref $value eq 'HASH';

    return {};
}

sub _positive_integer ($value) {
    return $value
      if defined $value
      && $value =~ /\A [[:digit:]]+ \z/msx
      && $value >= $MIN_VERSION;

    return $DEFAULT_VERSION;
}

sub _required ( $name, $value ) {
    die "$name is required" if !defined $value || !length "$value";

    return "$value";
}

1;
