package GPForum::Service::Projection::OffsetTracker;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $CURRENT_STATUS     => 'current';
const my $CATCHING_UP_STATUS => 'catching_up';
const my $FAILED_STATUS      => 'failed';
const my $ZERO_LAG           => 0;

has schema => undef;
has clock  => sub { return GPForum::Service::Clock->new; };

sub record_progress {
    my ( $self, $projection_name, $event ) = @_;

    my $lag_seconds = $self->_lag_seconds($event);
    my $row         = {
        projection_name       => $projection_name,
        last_event_id         => $event->{event_id},
        last_event_created_at => $event->{event_created_at},
        lag_seconds           => $lag_seconds,
        status                => _status_for_lag($lag_seconds),
        updated_at            => $self->clock->now_iso8601,
    };

    $self->schema->resultset('ProjectionOffset')->update_or_create($row);

    return $row;
}

sub mark_failed {
    my ( $self, $projection_name ) = @_;

    my $row = {
        projection_name => $projection_name,
        lag_seconds     => $ZERO_LAG,
        status          => $FAILED_STATUS,
        updated_at      => $self->clock->now_iso8601,
    };

    $self->schema->resultset('ProjectionOffset')->update_or_create($row);

    return $row;
}

sub observe_lag {
    my ( $self, $projection_name ) = @_;

    my $row =
      $self->schema->resultset('ProjectionOffset')->find($projection_name);

    return if !$row;

    return {
        projection_name => $row->get_column('projection_name'),
        lag_seconds     => $row->get_column('lag_seconds'),
        status          => $row->get_column('status'),
        updated_at      => $row->get_column('updated_at'),
    };
}

sub _lag_seconds {
    my ( $self, $event ) = @_;

    my $event_epoch = $event->{event_created_epoch} || $self->clock->now_epoch;
    my $lag_seconds = $self->clock->now_epoch - $event_epoch;

    return $lag_seconds > $ZERO_LAG ? $lag_seconds : $ZERO_LAG;
}

sub _status_for_lag {
    my ($lag_seconds) = @_;

    return $lag_seconds > $ZERO_LAG ? $CATCHING_UP_STATUS : $CURRENT_STATUS;
}

1;
