package GPForum::Service::Realtime::EventEnvelope;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;
use Mojo::JSON qw(decode_json encode_json);

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $DEFAULT_SCHEMA_VERSION => 1;
const my $MAX_PAYLOAD_BYTES      => 8192;
const my $TYPE_FRAGMENT          => qr/[[:lower:]][[:lower:][:digit:]_]*/msx;
const my $TYPE_PATTERN => qr/\A $TYPE_FRAGMENT (?: [.] $TYPE_FRAGMENT )+ \z/msx;

has clock             => sub { return GPForum::Service::Clock->new; };
has id_service        => sub { return GPForum::Service::Id->new; };
has max_payload_bytes => $MAX_PAYLOAD_BYTES;

sub build {
    my ( $self, %input ) = @_;

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

sub validate {
    my ( $self, $event ) = @_;

    return _invalid('malformed_payload') if ref $event ne 'HASH';

    my $reason = _event_rejection_reason($event);
    return _invalid($reason) if $reason;

    my $size = length encode_json($event);
    return _invalid('payload_too_large') if $size > $self->max_payload_bytes;

    return { ok => 1, bytes => $size };
}

sub _event_rejection_reason {
    my ($event) = @_;

    return
         _missing_required_field($event)
      || _type_rejection_reason($event)
      || _schema_version_rejection_reason($event)
      || _payload_rejection_reason($event)
      || _metadata_rejection_reason($event);
}

sub _missing_required_field {
    my ($event) = @_;

    for my $field (qw(event_id type schema_version occurred_at payload)) {
        if ( !defined $event->{$field} || !length "$event->{$field}" ) {
            return 'missing_' . $field;
        }
    }

    return;
}

sub _type_rejection_reason {
    my ($event) = @_;

    return if $event->{type} =~ $TYPE_PATTERN;

    return 'invalid_type';
}

sub _schema_version_rejection_reason {
    my ($event) = @_;

    if (   $event->{schema_version} =~ /\A [[:digit:]]+ \z/msx
        && $event->{schema_version} >= 1 )
    {
        return;
    }

    return 'invalid_schema_version';
}

sub _payload_rejection_reason {
    my ($event) = @_;

    return if ref $event->{payload} eq 'HASH';

    return 'invalid_payload';
}

sub _metadata_rejection_reason {
    my ($event) = @_;

    return if !exists $event->{metadata};

    return if ref $event->{metadata} eq 'HASH';

    return 'invalid_metadata';
}

sub serialize {
    my ( $self, $event ) = @_;

    my $validation = $self->validate($event);
    return $validation if !$validation->{ok};

    return {
        ok    => 1,
        bytes => $validation->{bytes},
        json  => encode_json($event),
    };
}

sub deserialize {
    my ( $self, $json ) = @_;

    return _invalid('payload_too_large')
      if defined $json && length($json) > $self->max_payload_bytes;

    my $event = eval { return decode_json($json); };
    return _invalid('malformed_payload') if !$event;

    my $validation = $self->validate($event);
    return $validation if !$validation->{ok};

    return { ok => 1, event => $event, bytes => $validation->{bytes} };
}

sub _schema_version {
    my ($value) = @_;

    return $value
      if defined $value
      && $value =~ /\A [[:digit:]]+ \z/msx
      && $value >= 1;

    return $DEFAULT_SCHEMA_VERSION;
}

sub _hash {
    my ($value) = @_;

    return { %{$value} } if ref $value eq 'HASH';

    return {};
}

sub _invalid {
    my ($reason) = @_;

    return { ok => 0, reason => $reason };
}

1;
