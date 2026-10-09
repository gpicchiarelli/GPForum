# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Projection::GenerationManager;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::X::Conflict;
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
const my $ACTIVE_CONSTRAINT => 'idx_projection_generations_one_active';
const my @GENERATION_COLUMNS => qw(
  activated_at
  built_from_event_created_at
  built_from_event_id
  created_at
  generation_id
  is_active
  projection_name
  status
);

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
__PACKAGE__->requires(qw(schema));

# A generation id that collides is drawn again, once; a start from the same
# event that a concurrent one inserted first is answered with that row.
sub start_generation ( $self, $projection_name, $event ) {
    my $input = {
        event           => $event,
        projection_name => $projection_name,
    };
    my $existing = $self->_existing_generation($input);
    return _skipped_generation($existing) if $existing;

    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_generation($input); } );
    return $created if $created;

    my $conflict = GPForum::X::Conflict->caught($error);
    if ( !$conflict
        || !(  $conflict->on($ID_CONSTRAINT)
            || $conflict->on($SOURCE_CONSTRAINT) ) )
    {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    $existing = $self->_existing_generation($input);
    return _skipped_generation($existing) if $existing;
    if ( $conflict->on($SOURCE_CONSTRAINT) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_generation($input); } );
    return $created if $created;

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub mark_ready ( $self, $generation_id ) {
    return $self->_update_generation( $generation_id,
        { status => $READY_STATUS } );
}

sub mark_failed ( $self, $generation_id ) {
    return $self->_update_generation( $generation_id,
        { status => $FAILED_STATUS } );
}

# An activation that loses the one-active index to a concurrent one keeps the
# winner when it activated this same generation, and retires it otherwise.
sub activate_generation ( $self, $generation_id ) {
    my $generation = $self->_find_generation($generation_id);
    return _skipped_activation($generation) if _already_active($generation);

    my ( $activated, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_activate_once($generation); } );
    return $activated if $activated;

    my $conflict = GPForum::X::Conflict->caught($error);
    if ( !$conflict || !$conflict->on($ACTIVE_CONSTRAINT) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    my $reloaded =
      $self->_find_generation( _column( $generation, 'generation_id' ) );
    return _skipped_activation($reloaded) if _already_active($reloaded);
    if ( !$reloaded ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_activate_once($reloaded);
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
    my $search = $self->schema->resultset('ProjectionGeneration')->search_rs(
        {
            built_from_event_id => $input->{event}{event_id},
            projection_name     => $input->{projection_name},
        },
        { rows => $ROW_LIMIT_ONE },
    );

    return $search && $search->can('single') ? $search->single : undef;
}

sub _skipped_generation ($existing) {
    return {
        ( map { $_ => _column( $existing, $_ ) } @GENERATION_COLUMNS ),
        skipped => 1,
    };
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
    return 0 if !$generation || !_column( $generation, 'is_active' );

    my $status = _column( $generation, 'status' ) || q{};
    return $status eq $ACTIVE_STATUS ? 1 : 0;
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
    my $held       = $generation && ( _column( $generation, 'status' ) || q{} );
    if ( $generation && $held eq ( $changes->{status} || q{} ) ) {
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

__END__

=head1 NAME

GPForum::Service::Projection::GenerationManager - Start, finish and switch the generations of a rebuilt projection.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $generations = GPForum::Service::Projection::GenerationManager->new(
        schema => $schema,
    );
    my $generation = $generations->start_generation(
        'search',
        { event_id => $event_id, event_created_at => $event_created_at },
    );
    # ... build the new read model ...
    $generations->mark_ready( $generation->{generation_id} );
    $generations->activate_generation( $generation->{generation_id} );

    # or, when the build fails
    $generations->mark_failed( $generation->{generation_id} );

=head1 DESCRIPTION

A projection can be rebuilt beside the copy that is serving reads. Each
build is a row in C<projection_generations>, which moves from C<building>
to C<ready> or C<failed>; activating one marks it C<active> and retires the
generation that was active before, so the switch is explicit and a
projection has at most one active generation (a partial unique index
enforces it).

Every step can be repeated safely. A build is identified by the projection
name and the event it was built from: starting it again returns the
existing generation instead of a second row, and a race between two
starters ends on the same row (a unique index backs that rule; inserts run
under savepoints through L<GPForum::Infrastructure::UniqueConflict>).
Marking a generation with the status it already has, or activating the
generation that is already active, writes nothing and says so with
C<skipped>.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> is required; C<clock> and C<id_service>
default to L<GPForum::Service::Clock> and L<GPForum::Infrastructure::Id>.

=head2 start_generation

Takes a projection name and an event hash reference with C<event_id> and
C<event_created_at>. Inserts a C<building>, inactive generation and returns
its hash (C<generation_id>, C<projection_name>, C<built_from_event_id>,
C<built_from_event_created_at>, C<status>, C<is_active>, C<created_at>,
C<activated_at>). When a generation of that projection was already built
from that event, returns that generation's hash with C<< skipped => 1 >>
instead. A conflict on the generated id is retried once with a fresh id.

=head2 mark_ready

Takes a generation id and sets its status to C<ready>. Returns
C<< { generation_id, status => 'ready' } >>, with C<< skipped => 1 >> when
the status was already C<ready>.

=head2 mark_failed

Takes a generation id and sets its status to C<failed>. Returns
C<< { generation_id, status => 'failed' } >>, with C<< skipped => 1 >> when
the status was already C<failed>.

=head2 activate_generation

Takes a generation id. Retires every active generation of the same
projection (C<< is_active => 0 >>, status C<retired>) and makes this one
active with the current time as C<activated_at>. Returns
C<< { generation_id, projection_name, retired_generations => $count, status => 'active' } >>.
When the generation is already active, returns the same keys with
C<< retired_generations => 0 >> and C<< skipped => 1 >>. When a concurrent
activation trips the one-active index, the generation is reloaded: if it
is now active the call reports it as skipped, otherwise the switch is
tried once more.

=head1 DIAGNOSTICS

Database errors other than the handled unique conflicts are rethrown.
C<mark_ready>, C<mark_failed> and C<activate_generation> die when the
generation id matches no row.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Infrastructure::Row>,
L<GPForum::Infrastructure::Id>, L<GPForum::Service::Clock>.

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
