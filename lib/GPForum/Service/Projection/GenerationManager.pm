# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Projection::GenerationManager;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;

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
has id_service => sub { return GPForum::Infrastructure::Id->new; };
has schema     => undef;

sub start_generation ( $self, $projection_name, $event ) {
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

sub _insert_or_reuse_generation ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_generation($input); },
      );
    if ($created) {
        return $created;
    }

    return $self->_generation_after_conflict( $input, $error );
}

sub _generation_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_generation_after_unique( $input, $error );
}

sub _generation_after_unique ( $self, $input, $error ) {
    if ( _generation_id_conflict($error) ) {
        return $self->_generation_after_id_conflict($input);
    }
    if ( _generation_source_conflict($error) ) {
        return $self->_reuse_generation_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _generation_after_id_conflict ( $self, $input ) {
    my $existing = $self->_existing_generation($input);
    if ($existing) {
        return _skipped_generation($existing);
    }

    return $self->_retry_generation_id($input);
}

sub _retry_generation_id ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_generation($input); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reuse_generation_row ( $self, $input, $error ) {
    my $existing = $self->_existing_generation($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return _skipped_generation($existing);
}

sub _generation_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _generation_source_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $SOURCE_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_generation ( $self, $input ) {
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

sub _existing_generation ( $self, $input ) {
    my $event  = $input->{event};
    my $search = $self->schema->resultset('ProjectionGeneration')->search_rs(
        {
            built_from_event_id => $event->{event_id},
            projection_name     => $input->{projection_name},
        },
        { rows => $ROW_LIMIT_ONE },
    );

    return _first_generation($search);
}

sub _first_generation ($search) {
    if ( $search && $search->can('single') ) {
        return $search->single;
    }

    my $undefined;
    return $undefined;
}

sub _skipped_generation ($existing) {
    return { %{ _generation_hash($existing) }, skipped => 1 };
}

sub _generation_hash ($generation) {
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

sub mark_ready ( $self, $generation_id ) {
    return $self->_update_generation(
        $generation_id,
        {
            status => $READY_STATUS,
        }
    );
}

sub mark_failed ( $self, $generation_id ) {
    return $self->_update_generation(
        $generation_id,
        {
            status => $FAILED_STATUS,
        }
    );
}

sub activate_generation ( $self, $generation_id ) {
    my $generation = $self->_find_generation($generation_id);
    if ( _already_active($generation) ) {
        return _skipped_activation($generation);
    }

    return $self->_activate_or_reuse($generation);
}

sub _activate_or_reuse ( $self, $generation ) {
    my ( $activated, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_activate_once($generation); },
      );
    if ($activated) {
        return $activated;
    }

    return $self->_activation_after_conflict( $generation, $error );
}

sub _activation_after_conflict ( $self, $generation, $error ) {
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

sub _write_after_conflict ( $self, $generation, $error ) {
    if ( !$generation ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_activate_once($generation);
}

sub _activate_once ( $self, $generation ) {
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

sub _already_active ($generation) {
    if ( !_is_active($generation) ) {
        return 0;
    }

    my $status = _column( $generation, 'status' ) || q{};
    return $status eq $ACTIVE_STATUS ? 1 : 0;
}

sub _is_active ($generation) {
    if ( !$generation ) {
        return 0;
    }

    return _column( $generation, 'is_active' ) ? 1 : 0;
}

sub _skipped_activation ($generation) {
    return {
        generation_id       => _column( $generation, 'generation_id' ),
        projection_name     => _column( $generation, 'projection_name' ),
        retired_generations => 0,
        skipped             => 1,
        status              => $ACTIVE_STATUS,
    };
}

sub _update_generation ( $self, $generation_id, $changes ) {
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

sub _same_status ( $generation, $changes ) {
    if ( !$generation ) {
        return 0;
    }

    my $held     = _column( $generation, 'status' ) || q{};
    my $incoming = $changes->{status}               || q{};
    return $held eq $incoming ? 1 : 0;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

sub _find_generation ( $self, $generation_id ) {
    return $self->schema->resultset('ProjectionGeneration')
      ->find($generation_id);
}

sub _active_generations ( $self, $projection_name ) {
    my $search = $self->schema->resultset('ProjectionGeneration')->search_rs(
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
