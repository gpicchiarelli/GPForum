package GPForum::Service::Admin::RoleBindingStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Admin::Event;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $ROW_LIMIT_ONE => 1;

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
has events => sub { return GPForum::Service::Admin::Event->new; };

sub bind_role {
    my ( $self, $input ) = @_;

    my $existing = $self->_active_binding($input);
    return {
        ok         => 1,
        idempotent => 1,
        binding    => _binding_hash($existing),
      }
      if $existing;

    my $created_at = $self->clock->now_iso8601;
    my $binding    = {
        binding_id         => $self->id_service->uuid,
        user_id            => $input->{user_id},
        role_id            => $input->{role_id},
        resource_type      => $input->{resource_type},
        resource_id        => $input->{resource_id},
        space_id           => $input->{space_id},
        created_by_user_id => $input->{actor_user_id},
        created_at         => $created_at,
        revoked_at         => undef,
    };
    $self->schema->resultset('RoleBinding')->create($binding);
    $self->_record_audit(
        {
            action        => 'role_binding.created',
            actor_user_id => $input->{actor_user_id},
            binding       => $binding,
            created_at    => $created_at,
        }
    );

    return { ok => 1, binding => $binding };
}

sub revoke_binding {
    my ( $self, $binding_id, $actor_user_id ) = @_;

    my $revoked_at = $self->clock->now_iso8601;
    my $binding    = $self->schema->resultset('RoleBinding')->find($binding_id);
    return if !$binding;

    return {
        binding_id => $binding_id,
        idempotent => 1,
        revoked_at => $binding->get_column('revoked_at'),
      }
      if defined $binding->get_column('revoked_at');

    $binding->update( { revoked_at => $revoked_at } );
    $self->_record_audit(
        {
            action        => 'role_binding.revoked',
            actor_user_id => $actor_user_id,
            binding       => {
                binding_id    => $binding_id,
                resource_id   => $binding->get_column('resource_id'),
                resource_type => $binding->get_column('resource_type'),
                role_id       => $binding->get_column('role_id'),
                space_id      => $binding->get_column('space_id'),
                user_id       => $binding->get_column('user_id'),
            },
            created_at => $revoked_at,
        }
    );

    return {
        binding_id => $binding_id,
        revoked_at => $revoked_at,
    };
}

sub _active_binding {
    my ( $self, $input ) = @_;

    my $search = $self->schema->resultset('RoleBinding')->search(
        {
            user_id       => $input->{user_id},
            role_id       => $input->{role_id},
            resource_type => $input->{resource_type},
            resource_id   => $input->{resource_id},
            space_id      => $input->{space_id},
            revoked_at    => undef,
        },
        { rows => $ROW_LIMIT_ONE }
    );

    return $search->single if $search->can('single');

    if ( $search->can('all') ) {
        my @rows = $search->all;
        return $rows[0];
    }

    return $search->rows->[0] if $search->can('rows');

    return;
}

sub _binding_hash {
    my ($binding) = @_;

    return if !$binding;

    return {
        binding_id         => _column( $binding, 'binding_id' ),
        created_at         => _column( $binding, 'created_at' ),
        created_by_user_id => _column( $binding, 'created_by_user_id' ),
        resource_id        => _column( $binding, 'resource_id' ),
        resource_type      => _column( $binding, 'resource_type' ),
        revoked_at         => _column( $binding, 'revoked_at' ),
        role_id            => _column( $binding, 'role_id' ),
        space_id           => _column( $binding, 'space_id' ),
        user_id            => _column( $binding, 'user_id' ),
    };
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->{$column}           if ref $row eq 'HASH';
    return $row->get_column($column) if $row && $row->can('get_column');

    return;
}

sub _record_audit {
    my ( $self, $input ) = @_;

    $self->recorder->record_audit( %{ $self->events->binding_audit($input) } );

    return;
}

1;
