package GPForum::Service::Projection::GenerationManager;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $BUILDING_STATUS => 'building';
const my $READY_STATUS    => 'ready';
const my $ACTIVE_STATUS   => 'active';
const my $RETIRED_STATUS  => 'retired';
const my $FAILED_STATUS   => 'failed';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub start_generation {
    my ( $self, $projection_name, $event ) = @_;

    my $row = {
        generation_id               => $self->id_service->uuid,
        projection_name             => $projection_name,
        built_from_event_id         => $event->{event_id},
        built_from_event_created_at => $event->{event_created_at},
        is_active                   => 0,
        status                      => $BUILDING_STATUS,
        created_at                  => $self->clock->now_iso8601,
        activated_at                => undef,
    };

    $self->schema->resultset('ProjectionGeneration')->create($row);

    return $row;
}

sub mark_ready {
    my ( $self, $generation_id ) = @_;

    return $self->_update_generation(
        $generation_id,
        {
            status => $READY_STATUS,
        }
    );
}

sub mark_failed {
    my ( $self, $generation_id ) = @_;

    return $self->_update_generation(
        $generation_id,
        {
            status => $FAILED_STATUS,
        }
    );
}

sub activate_generation {
    my ( $self, $generation_id ) = @_;

    my $generation         = $self->_find_generation($generation_id);
    my $projection_name    = $generation->get_column('projection_name');
    my @active_generations = $self->_active_generations($projection_name);

    for my $active_generation (@active_generations) {
        $active_generation->update(
            {
                is_active => 0,
                status    => $RETIRED_STATUS,
            }
        );
    }

    $generation->update(
        {
            is_active    => 1,
            status       => $ACTIVE_STATUS,
            activated_at => $self->clock->now_iso8601,
        }
    );

    return {
        generation_id       => $generation_id,
        projection_name     => $projection_name,
        retired_generations => scalar @active_generations,
        status              => $ACTIVE_STATUS,
    };
}

sub _update_generation {
    my ( $self, $generation_id, $changes ) = @_;

    my $generation = $self->_find_generation($generation_id);
    $generation->update($changes);

    return {
        generation_id => $generation_id,
        %{$changes},
    };
}

sub _find_generation {
    my ( $self, $generation_id ) = @_;

    return $self->schema->resultset('ProjectionGeneration')
      ->find($generation_id);
}

sub _active_generations {
    my ( $self, $projection_name ) = @_;

    my $search = $self->schema->resultset('ProjectionGeneration')->search(
        {
            projection_name => $projection_name,
            is_active       => 1,
        }
    );

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
