# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::EventEnvelope;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;
use Mojo::JSON qw(decode_json encode_json);

use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;

our $VERSION = '0.001';

const my $DEFAULT_SCHEMA_VERSION => 1;
const my $MAX_PAYLOAD_BYTES      => 8192;
const my $TYPE_FRAGMENT          => qr/[[:lower:]][[:lower:][:digit:]_]*/msx;
const my $TYPE_PATTERN => qr/\A $TYPE_FRAGMENT (?: [.] $TYPE_FRAGMENT )+ \z/msx;

has clock             => sub { return GPForum::Service::Clock->new; };
has id_service        => sub { return GPForum::Infrastructure::Id->new; };
has max_payload_bytes => $MAX_PAYLOAD_BYTES;

sub build ( $self, %input ) {
    my $event = {
        event_id       => $input{event_id} || $self->id_service->uuid,
        type           => $input{type},
        schema_version => _schema_version( $input{schema_version} ),
        occurred_at    => $input{occurred_at} || $self->clock->now_iso8601,
        correlation_id => $input{correlation_id},
        causation_id   => $input{causation_id},
        aggregate_type => $input{aggregate_type},
        aggregate_id   => $input{aggregate_id},
        actor_id       => $input{actor_id},
        payload        => _hash( $input{payload} ),
        metadata       => _hash( $input{metadata} ),
    };

    return $event;
}

# The one shape of a badge frame, whoever sends it: the dispatcher through
# NOTIFY, the hub as a snapshot. They used to differ, one with the count at
# the top level and one only in the payload.
sub notification_badge ( $self, $user_id, $count ) {
    return $self->build(
        type           => 'notification.badge',
        aggregate_type => 'user',
        aggregate_id   => $user_id,
        payload        => { unread_count => $count },
        metadata       => { channel_type => 'notifications' },
    );
}

sub validate ( $self, $event ) {
    return _invalid('malformed_payload') if ref $event ne 'HASH';

    my $reason = _event_rejection_reason($event);
    return _invalid($reason) if $reason;

    my $size = length encode_json($event);
    return _invalid('payload_too_large') if $size > $self->max_payload_bytes;

    return { ok => 1, bytes => $size };
}

sub _event_rejection_reason ($event) {
    return
         _missing_required_field($event)
      || _type_rejection_reason($event)
      || _schema_version_rejection_reason($event)
      || _payload_rejection_reason($event)
      || _metadata_rejection_reason($event);
}

sub _missing_required_field ($event) {
    for my $field (qw(event_id type schema_version occurred_at payload)) {
        if ( !defined $event->{$field} || !length "$event->{$field}" ) {
            return 'missing_' . $field;
        }
    }

    my $undefined;
    return $undefined;
}

sub _type_rejection_reason ($event) {
    my $undefined;
    return $undefined if $event->{type} =~ $TYPE_PATTERN;

    return 'invalid_type';
}

sub _schema_version_rejection_reason ($event) {
    if (   $event->{schema_version} =~ /\A [[:digit:]]+ \z/msx
        && $event->{schema_version} >= 1 )
    {
        my $undefined;
        return $undefined;
    }

    return 'invalid_schema_version';
}

sub _payload_rejection_reason ($event) {
    my $undefined;
    return $undefined if ref $event->{payload} eq 'HASH';

    return 'invalid_payload';
}

sub _metadata_rejection_reason ($event) {
    my $undefined;
    return $undefined if !exists $event->{metadata};

    return $undefined if ref $event->{metadata} eq 'HASH';

    return 'invalid_metadata';
}

sub serialize ( $self, $event ) {
    my $validation = $self->validate($event);
    return $validation if !$validation->{ok};

    return {
        ok    => 1,
        bytes => $validation->{bytes},
        json  => encode_json($event),
    };
}

sub deserialize ( $self, $json ) {
    return _invalid('payload_too_large')
      if defined $json && length($json) > $self->max_payload_bytes;

    my $event = eval { return decode_json($json); };
    return _invalid('malformed_payload') if !$event;

    my $validation = $self->validate($event);
    return $validation if !$validation->{ok};

    return { ok => 1, event => $event, bytes => $validation->{bytes} };
}

sub _schema_version ($value) {
    return $value
      if defined $value
      && $value =~ /\A [[:digit:]]+ \z/msx
      && $value >= 1;

    return $DEFAULT_SCHEMA_VERSION;
}

sub _hash ($value) {
    return { %{$value} } if ref $value eq 'HASH';

    return {};
}

sub _invalid ($reason) {
    return { ok => 0, reason => $reason };
}

1;
