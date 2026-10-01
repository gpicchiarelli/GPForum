# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::SecurityTelemetry;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use GPForum::Service::Clock;

our $VERSION = '0.001';

has clock  => sub { return GPForum::Service::Clock->new; };
has events => sub { return {}; };
has total  => 0;

sub record ( $self, $event_type, $metadata ) {
    my $event = $self->events->{$event_type} ||= {
        count         => 0,
        last_seen_at  => undef,
        last_metadata => {},
    };
    $event->{count} += 1;
    $event->{last_seen_at}  = $self->clock->now_iso8601;
    $event->{last_metadata} = _safe_metadata($metadata);
    $self->total( $self->total + 1 );

    return {
        ok         => 1,
        event_type => $event_type,
        count      => $event->{count},
    };
}

sub snapshot ($self) {
    my %events =
      map { $_ => { %{ $self->events->{$_} } } } sort keys %{ $self->events };

    return {
        total  => $self->total,
        events => \%events,
    };
}

sub _safe_metadata ($metadata) {
    return {} if !$metadata;

    my %safe;
    for my $name (
        qw(
        action route status store degraded reason channel_type payload_size
        )
      )
    {
        $safe{$name} = $metadata->{$name} if defined $metadata->{$name};
    }

    return \%safe;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::SecurityTelemetry - Per-process counters of security events for the metrics snapshot.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $telemetry = GPForum::Service::Operations::SecurityTelemetry->new;

    $telemetry->record(
        'session_validation_unavailable',
        { reason => 'store_error', route => 'forum_home', status => 503 },
    );

    my $snapshot = $telemetry->snapshot;
    # { total => 1, events => { session_validation_unavailable => {...} } }

=head1 DESCRIPTION

Counts security-relevant events (rate limit hits, session validation
failures and the like) by event type, in memory, for the life of the
process. Each type keeps its count, when it was last seen, and the metadata
of its last occurrence. Only a fixed set of metadata keys is kept --
C<action>, C<route>, C<status>, C<store>, C<degraded>, C<reason>,
C<channel_type> and C<payload_size> -- so nothing personal reaches the
metrics endpoint through this class.

=head1 SUBROUTINES/METHODS

=head2 record

Takes an event type and a metadata hash reference (or undef). Increments the
type's count and the total, stamps C<last_seen_at> from the clock, and keeps
the allowed metadata keys that are defined. Returns
C<< { ok => 1, event_type => $type, count => $count } >>.

=head2 snapshot

Returns C<< { total => $n, events => { TYPE => { count, last_seen_at,
last_metadata } } } >>, with a shallow copy of each event's hash.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The counters live in one process: under several workers each keeps its own,
and a restart clears them.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
