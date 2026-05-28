package GPForum::Service::Operations::SecurityTelemetry;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Clock;

our $VERSION = '0.001';

has clock  => sub { return GPForum::Service::Clock->new; };
has events => sub { return {}; };
has total  => 0;

sub record {
    my ( $self, $event_type, $metadata ) = @_;

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

sub snapshot {
    my ($self) = @_;

    my %events =
      map { $_ => { %{ $self->events->{$_} } } } sort keys %{ $self->events };

    return {
        total  => $self->total,
        events => \%events,
    };
}

sub _safe_metadata {
    my ($metadata) = @_;

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
