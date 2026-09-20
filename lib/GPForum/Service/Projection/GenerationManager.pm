package GPForum::Service::Projection::GenerationManager;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $BUILDING_STATUS   => 'building';
const my $READY_STATUS      => 'ready';
const my $ACTIVE_STATUS     => 'active';
const my $RETIRED_STATUS    => 'retired';
const my $FAILED_STATUS     => 'failed';
const my $ROW_LIMIT_ONE     => 1;
const my $ID_CONSTRAINT     => 'projection_generations_pkey';
const my $SOURCE_CONSTRAINT => 'idx_projection_generations_source_unique';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub start_generation {
    my ( $self, $projection_name, $event ) = @_;

    my $input = {
        event           => $event,
        projection_name => $projection_name,
    };
    my $existing = $self->_existing_generation($input);
    if ($existing) {
        return _skipped_generation($existing);
    }

    return $self->_insert_or_reuse_generation($input);
}

sub _insert_or_reuse_generation {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_generation($input); };
    if ($created) {
        return $created;
    }

    return $self->_generation_after_conflict( $input, $EVAL_ERROR );
}

sub _generation_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_generation_after_unique( $input, $error );
}

sub _generation_after_unique {
    my ( $self, $input, $error ) = @_;

    if ( _generation_id_conflict($error) ) {
        return $self->_generation_after_id_conflict($input);
    }
    if ( _generation_source_conflict($error) ) {
        return $self->_reuse_generation_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _generation_after_id_conflict {
    my ( $self, $input ) = @_;

    my $existing = $self->_existing_generation($input);
    if ($existing) {
        return _skipped_generation($existing);
    }

    return $self->_retry_generation_id($input);
}

sub _retry_generation_id {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_generation($input); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _reuse_generation_row {
    my ( $self, $input, $error ) = @_;

    my $existing = $self->_existing_generation($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return _skipped_generation($existing);
}

sub _generation_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _generation_source_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $SOURCE_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_generation {
    my ( $self, $input ) = @_;

    my $event = $input->{event};
    my $row   = {
        activated_at                => undef,
        built_from_event_created_at => $event->{event_created_at},
        built_from_event_id         => $event->{event_id},
        created_at                  => $self->clock->now_iso8601,
        generation_id               => $self->id_service->uuid,
        is_active                   => 0,
        projection_name             => $input->{projection_name},
        status                      => $BUILDING_STATUS,
    };
    $self->schema->resultset('ProjectionGeneration')->create($row);

    return $row;
}

sub _existing_generation {
    my ( $self, $input ) = @_;

    my $event  = $input->{event};
    my $search = $self->schema->resultset('ProjectionGeneration')->search(
        {
            built_from_event_id => $event->{event_id},
            projection_name     => $input->{projection_name},
        },
        { rows => $ROW_LIMIT_ONE },
    );

    return _first_generation($search);
}

sub _first_generation {
    my ($search) = @_;

    if ( $search && $search->can('single') ) {
        return $search->single;
    }

    return;
}

sub _skipped_generation {
    my ($existing) = @_;

    return { %{ _generation_hash($existing) }, skipped => 1 };
}

sub _generation_hash {
    my ($generation) = @_;

    return {
        activated_at                => _column( $generation, 'activated_at' ),
        built_from_event_created_at =>
          _column( $generation, 'built_from_event_created_at' ),
        built_from_event_id => _column( $generation, 'built_from_event_id' ),
        created_at          => _column( $generation, 'created_at' ),
        generation_id       => _column( $generation, 'generation_id' ),
        is_active           => _column( $generation, 'is_active' ),
        projection_name     => _column( $generation, 'projection_name' ),
        status              => _column( $generation, 'status' ),
    };
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

    my $generation = $self->_find_generation($generation_id);
    if ( _already_active($generation) ) {
        return _skipped_activation($generation);
    }

    return $self->_activate_or_reuse($generation);
}

sub _activate_or_reuse {
    my ( $self, $generation ) = @_;

    my $activated = eval { return $self->_activate_once($generation); };
    if ($activated) {
        return $activated;
    }

    return $self->_activation_after_conflict( $generation, $EVAL_ERROR );
}

sub _activation_after_conflict {
    my ( $self, $generation, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $reloaded =
      $self->_find_generation( _column( $generation, 'generation_id' ) );
    if ( _already_active($reloaded) ) {
        return _skipped_activation($reloaded);
    }

    return $self->_write_after_conflict( $reloaded, $error );
}

sub _write_after_conflict {
    my ( $self, $generation, $error ) = @_;

    if ( !$generation ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_activate_once($generation);
}

sub _activate_once {
    my ( $self, $generation ) = @_;

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
        generation_id       => _column( $generation, 'generation_id' ),
        projection_name     => $projection_name,
        retired_generations => scalar @active_generations,
        status              => $ACTIVE_STATUS,
    };
}

sub _already_active {
    my ($generation) = @_;

    if ( !_is_active($generation) ) {
        return 0;
    }

    my $status = _column( $generation, 'status' ) || q{};
    return $status eq $ACTIVE_STATUS ? 1 : 0;
}

sub _is_active {
    my ($generation) = @_;

    if ( !$generation ) {
        return 0;
    }

    return _column( $generation, 'is_active' ) ? 1 : 0;
}

sub _skipped_activation {
    my ($generation) = @_;

    return {
        generation_id       => _column( $generation, 'generation_id' ),
        projection_name     => _column( $generation, 'projection_name' ),
        retired_generations => 0,
        skipped             => 1,
        status              => $ACTIVE_STATUS,
    };
}

sub _update_generation {
    my ( $self, $generation_id, $changes ) = @_;

    my $generation = $self->_find_generation($generation_id);
    if ( _same_status( $generation, $changes ) ) {
        return {
            generation_id => $generation_id,
            skipped       => 1,
            %{$changes},
        };
    }

    $generation->update($changes);

    return {
        generation_id => $generation_id,
        %{$changes},
    };
}

sub _same_status {
    my ( $generation, $changes ) = @_;

    if ( !$generation ) {
        return 0;
    }

    my $held     = _column( $generation, 'status' ) || q{};
    my $incoming = $changes->{status}               || q{};
    return $held eq $incoming ? 1 : 0;
}

sub _column {
    my ( $row, $name ) = @_;

    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }
    if ( $row && $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return;
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
