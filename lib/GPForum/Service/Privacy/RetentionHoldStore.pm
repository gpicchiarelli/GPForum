package GPForum::Service::Privacy::RetentionHoldStore;

use strict;
use warnings;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Clock;
use GPForum::Service::Privacy::Event;
use GPForum::Service::Privacy::Record;
use Mojo::Base -base;

our $VERSION = '0.001';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
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

sub create_hold {
    my ( $self, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            return $self->_insert_hold($input);
        }
    );
}

sub active_holds_for {
    my ( $self, $resource_type, $resource_id, $limit ) = @_;

    my $search = $self->schema->resultset('RetentionHold')->search(
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

sub _insert_hold {
    my ( $self, $input ) = @_;

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

sub _record_event_and_audit {
    my ( $self, $hold, $actor_id ) = @_;

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
writes RetentionHold rows, EventLog, OutboxMessage, and AuditLog.

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

Uses L<GPForum::Infrastructure::EventRecorder>, L<GPForum::Service::Clock>,
L<GPForum::Service::Privacy::Event>, L<GPForum::Service::Privacy::Record>,
and L<Mojo::Base>. C<GPForum::Service::Id> is required lazily unless an
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
