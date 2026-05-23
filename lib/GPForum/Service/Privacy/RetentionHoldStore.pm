package GPForum::Service::Privacy::RetentionHoldStore;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub create_hold {
    my ( $self, $input ) = @_;

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

    return $hold;
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

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
