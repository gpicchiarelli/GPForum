# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::EventEnvelope;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;
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

__END__

=head1 NAME

GPForum::Service::Realtime::EventEnvelope - Builds, checks and encodes realtime event frames.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $contract = GPForum::Service::Realtime::EventEnvelope->new;
    my $event = $contract->build(
        type           => 'thread.update',
        aggregate_type => 'thread',
        aggregate_id   => $thread_id,
        payload        => { thread_id => $thread_id },
    );
    my $encoded = $contract->serialize($event);
    die $encoded->{reason} if !$encoded->{ok};

    my $decoded = $contract->deserialize( $encoded->{json} );
    my $frame   = $decoded->{ok} ? $decoded->{event} : undef;

=head1 DESCRIPTION

The one shape of an event sent to browsers over the realtime channel,
used by whoever writes a frame (L<GPForum::Service::Realtime::PgNotifier>,
L<GPForum::Service::Notification::Dispatcher>,
L<GPForum::Service::Realtime::OutboxEventMapper>) and by whoever reads one
(L<GPForum::Service::Realtime::PgListener>,
L<GPForum::Service::Realtime::Hub>).

A frame is a hash reference with C<event_id>, C<type>, C<schema_version>,
C<occurred_at>, C<correlation_id>, C<causation_id>, C<aggregate_type>,
C<aggregate_id>, C<actor_id>, C<payload> and C<metadata>. A valid frame
has a non-empty C<event_id>, C<type>, C<schema_version>, C<occurred_at>
and C<payload>; a C<type> of two or more dot-separated lower-case words
(letters, digits and underscores, starting with a letter); a whole
C<schema_version> of at least 1; a hash reference C<payload>; a hash
reference C<metadata> when it is present; and a JSON encoding no longer
than C<max_payload_bytes> (default 8192).

Validation does not die: it returns C<< { ok => 0, reason => ... } >>,
the reason one of C<malformed_payload>, C<missing_event_id>,
C<missing_type>, C<missing_schema_version>, C<missing_occurred_at>,
C<missing_payload>, C<invalid_type>, C<invalid_schema_version>,
C<invalid_payload>, C<invalid_metadata> or C<payload_too_large>.

The attributes are C<clock> and C<id_service>, which supply the defaults
of C<build>, and C<max_payload_bytes>.

=head1 SUBROUTINES/METHODS

=head2 build

Takes a hash of the frame's fields. Returns a new frame hash reference:
C<event_id> defaults to a fresh uuid, C<occurred_at> to the clock's time
and C<schema_version> to 1 (also when the one given is not a whole number
of at least 1); C<payload> and C<metadata> are shallow copies, or empty
hashes when not hash references. It does not validate the frame.

=head2 notification_badge

Takes a user id and an unread count. Returns the C<notification.badge>
frame for that user: aggregate C<user>, C<< payload => { unread_count } >>
and C<< metadata => { channel_type => 'notifications' } >>. The dispatcher
and the hub both send this frame, so a badge has one shape whoever sends
it.

=head2 validate

Takes a frame. Returns C<< { ok => 1, bytes => $size } >>, the size of
its JSON encoding, when the frame is valid; otherwise
C<< { ok => 0, reason => $reason } >>.

=head2 serialize

Takes a frame. Returns C<< { ok => 1, bytes, json } >> with the frame's
JSON encoding when it is valid, or the failed validation.

=head2 deserialize

Takes a JSON string. Returns C<< { ok => 1, event, bytes } >> when it
decodes to a valid frame; otherwise C<< { ok => 0, reason } >>, with
C<payload_too_large> for a string longer than C<max_payload_bytes>
(checked before decoding) and C<malformed_payload> for one that does not
decode to a hash reference.

=head1 DIAGNOSTICS

None: every rejection is a C<reason> in the returned hash.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, L<Mojo::JSON>, L<GPForum::Service::Clock>,
L<GPForum::Infrastructure::Id>.

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
