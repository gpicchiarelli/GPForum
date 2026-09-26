# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Privacy::RetentionHoldStore;

use strict;
use warnings;

use Const::Fast;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Privacy::Event;
use GPForum::Service::Privacy::Record;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $ACTIVE_CONSTRAINT => 'idx_retention_holds_active_resource_unique';
const my $ID_CONSTRAINT     => 'retention_holds_pkey';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema => undef;
has record => sub { return GPForum::Service::Privacy::Record->new; };
has events => sub {
    my ($self) = @_;

    return GPForum::Service::Privacy::Event->new( record => $self->record );
};

sub create_hold ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            return $self->_create_or_reuse_hold($input);
        }
    );
}

sub _create_or_reuse_hold ( $self, $input ) {
    my $existing = $self->_active_hold_hash($input);
    if ($existing) {
        return $self->_finish_leftover_hold( $existing, $input );
    }

    return $self->_insert_or_reuse_hold($input);
}

sub _insert_or_reuse_hold ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_hold($input); },
      );
    if ($created) {
        return $created;
    }

    return $self->_reuse_after_conflict( $input, $error );
}

sub _reuse_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_hold_after_unique( $input, $error );
}

sub _hold_after_unique ( $self, $input, $error ) {
    if ( _hold_id_conflict($error) ) {
        return $self->_hold_after_id_conflict($input);
    }
    if ( _active_hold_conflict($error) ) {
        return $self->_reuse_hold_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _hold_after_id_conflict ( $self, $input ) {
    my $existing = $self->_active_hold_hash($input);
    if ($existing) {
        return $self->_finish_leftover_hold( $existing, $input );
    }

    return $self->_retry_hold_id($input);
}

sub _retry_hold_id ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_hold($input); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reuse_hold_row ( $self, $input, $error ) {
    my $existing = $self->_active_hold_hash($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_finish_leftover_hold( $existing, $input );
}

sub _hold_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _active_hold_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ACTIVE_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _active_hold_hash ( $self, $input ) {
    my $holds = $self->active_holds_for( $input->{resource_type},
        $input->{resource_id}, 1 );
    if ( !@{$holds} ) {
        my $undefined;
        return $undefined;
    }

    return $self->_hold_hash( $holds->[0] );
}

sub _hold_hash ( $self, $hold ) {
    return {
        created_at        => $self->record->column( $hold, 'created_at' ),
        created_by        => $self->record->column( $hold, 'created_by' ),
        ends_at           => $self->record->column( $hold, 'ends_at' ),
        reason            => $self->record->column( $hold, 'reason' ),
        resource_id       => $self->record->column( $hold, 'resource_id' ),
        resource_type     => $self->record->column( $hold, 'resource_type' ),
        retention_hold_id =>
          $self->record->column( $hold, 'retention_hold_id' ),
        starts_at => $self->record->column( $hold, 'starts_at' ),
    };
}

sub active_holds_for ( $self, $resource_type, $resource_id, $limit ) {
    my $search = $self->schema->resultset('RetentionHold')->search_rs(
        {
            ends_at       => undef,
            resource_id   => $resource_id,
            resource_type => $resource_type,
        },
        {
            order_by => [ { -desc => 'created_at' } ],
            rows     => $limit,
        }
    );

    return [ $self->record->rows($search) ];
}

sub _insert_hold ( $self, $input ) {
    my $timestamp = $self->clock->now_iso8601;
    my $hold      = {
        created_at        => $timestamp,
        created_by        => $input->{created_by},
        ends_at           => $input->{ends_at},
        reason            => $input->{reason},
        resource_id       => $input->{resource_id},
        resource_type     => $input->{resource_type},
        retention_hold_id => $self->id_service->uuid,
        starts_at         => $input->{starts_at} || $timestamp,
    };
    $self->schema->resultset('RetentionHold')->create($hold);
    $self->_record_event_and_audit( $hold, $input->{created_by} );

    return $hold;
}

sub _finish_leftover_hold ( $self, $existing, $input ) {
    $self->_ensure_hold_write( $existing, $input );

    return $existing;
}

sub _ensure_hold_write ( $self, $existing, $input ) {
    if ( $self->_hold_event_exists($existing) ) {
        my $undefined;
        return $undefined;
    }

    return $self->_record_event_and_audit( $existing, $input->{created_by} );
}

sub _hold_event_exists ( $self, $existing ) {
    return $self->recorder->event_recorded(
        join q{:},
        'privacy.retention_hold_created',
        $existing->{retention_hold_id}
    );
}

sub _record_event_and_audit ( $self, $hold, $actor_id ) {
    my $recorded = {
        actor_id       => $actor_id,
        correlation_id => $self->id_service->uuid,
        hold           => $hold,
    };
    $self->recorder->record_event(
        %{ $self->events->hold_envelope($recorded) } );
    $self->recorder->record_audit( %{ $self->events->hold_audit($recorded) } );

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Privacy::RetentionHoldStore - Retention hold persistence.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $hold = $store->create_hold($input);

=head1 DESCRIPTION

Creates retention holds and lists active holds for a resource. Event and
audit hashes live in L<GPForum::Service::Privacy::Event>. This store still
writes RetentionHold rows, EventLog, OutboxMessage, and AuditLog. A unique
partial index keeps one active hold per resource; a unique race on that
index reloads the winning row. A unique race on C<retention_hold_id> remints
the id once and does not return another hold.

=head1 SUBROUTINES/METHODS

=head2 create_hold

Inserts a hold inside a transaction and records the created event.

=head2 active_holds_for

Returns open holds for a resource type and id, newest first.

=head1 DIAGNOSTICS

None. Persistence errors stay in the schema transaction.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<GPForum::Infrastructure::EventRecorder>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Service::Clock>,
L<GPForum::Service::Privacy::Event>, L<GPForum::Service::Privacy::Record>,
and L<Mojo::Base>. C<GPForum::Infrastructure::Id> is required lazily unless an
C<id_service> is injected.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Public C<active_holds_for> still takes four arguments including the invocant.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
