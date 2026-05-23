package GPForum::Service::Operations::MetricsSnapshot;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Clock;

our $VERSION = '0.001';

has clock               => sub { return GPForum::Service::Clock->new; };
has rate_limiter        => undef;
has realtime_hub        => undef;
has projection_trackers => sub { return []; };
has runtime             => undef;

sub collect {
    my ($self) = @_;

    return {
        generated_at => $self->clock->now_iso8601,
        runtime      => $self->runtime ? $self->runtime->as_hash : {},
        realtime     => $self->_realtime,
        rate_limits  => $self->_rate_limits,
        projections  => $self->_projections,
    };
}

sub _realtime {
    my ($self) = @_;

    return {} if !$self->realtime_hub;

    return $self->realtime_hub->snapshot;
}

sub _rate_limits {
    my ($self) = @_;

    return {} if !$self->rate_limiter;

    return $self->rate_limiter->snapshot;
}

sub _projections {
    my ($self) = @_;

    return [
        grep { defined }
        map  { $_->observe_lag } @{ $self->projection_trackers }
    ];
}

1;

