package GPForum::Service::Privacy::RetentionHoldStore;

use strict;
use warnings;

use Mojo::Base -base;

use Const::Fast;
use GPForum::Service::Clock;
use GPForum::Service::Id;
use GPForum::Service::Outbox::MessageBuilder;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;

has clock          => sub { return GPForum::Service::Clock->new; };
has id_service     => sub { return GPForum::Service::Id->new; };
has outbox_builder => sub {
    my ($self) = @_;

    return GPForum::Service::Outbox::MessageBuilder->new(
        id_service => $self->id_service, );
};
has schema => undef;

sub create_hold {
    my ( $self, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            my $timestamp = $self->clock->now_iso8601;
            my $hold      = {
                retention_hold_id => $self->id_service->uuid,
                resource_type     => $input->{resource_type},
                resource_id       => $input->{resource_id},
                reason            => $input->{reason},
                starts_at         => $input->{starts_at} || $timestamp,
                ends_at           => $input->{ends_at},
                created_by        => $input->{created_by},
                created_at        => $timestamp,
            };
            $self->schema->resultset('RetentionHold')->create($hold);
            $self->_record_event_and_audit( 'privacy.retention_hold_created',
                $hold, $input->{created_by}, );

            return $hold;
        }
    );
}

sub active_holds_for {
    my ( $self, $resource_type, $resource_id, $limit ) = @_;

    my $search = $self->schema->resultset('RetentionHold')->search(
        {
            resource_type => $resource_type,
            resource_id   => $resource_id,
            ends_at       => undef,
        },
        {
            order_by => [ { -desc => 'created_at' } ],
            rows     => $limit,
        }
    );

    return [ _rows($search) ];
}

sub _record_event_and_audit {
    my ( $self, $action, $hold, $actor_id ) = @_;

    my $correlation_id = $self->id_service->uuid;
    my $event          = {
        event_id          => $self->id_service->uuid,
        event_type        => $action,
        schema_version    => $SCHEMA_VERSION,
        aggregate_type    => $hold->{resource_type},
        aggregate_id      => $hold->{resource_id},
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $actor_id,
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   => join( q{:}, $action, $hold->{retention_hold_id} ),
        payload           => {
            retention_hold_id => $hold->{retention_hold_id},
            resource_type     => $hold->{resource_type},
            resource_id       => $hold->{resource_id},
            reason            => $hold->{reason},
            starts_at         => $hold->{starts_at},
            ends_at           => $hold->{ends_at},
        },
        metadata   => {},
        created_at => $hold->{created_at},
    };

    $self->schema->resultset('EventLog')->create($event);
    $self->schema->resultset('OutboxMessage')
      ->create( $self->outbox_builder->for_event($event) );
    $self->schema->resultset('AuditLog')->create(
        {
            audit_id       => $self->id_service->uuid,
            action         => $action,
            schema_version => $SCHEMA_VERSION,
            actor_id       => $actor_id,
            target_type    => $hold->{resource_type},
            target_id      => $hold->{resource_id},
            correlation_id => $correlation_id,
            previous_hash  => undef,
            record_hash    => q{},
            metadata       => {
                reason            => $hold->{reason},
                retention_hold_id => $hold->{retention_hold_id},
            },
            created_at => $hold->{created_at},
        }
    );

    return;
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
