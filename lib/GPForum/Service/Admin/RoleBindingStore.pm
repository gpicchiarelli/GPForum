package GPForum::Service::Admin::RoleBindingStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub bind_role {
    my ( $self, $input ) = @_;

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

    $binding->update( { revoked_at => $revoked_at } );
    $self->_record_audit(
        {
            action        => 'role_binding.revoked',
            actor_user_id => $actor_user_id,
            binding       => {
                binding_id => $binding_id,
                user_id    => $binding->get_column('user_id'),
                role_id    => $binding->get_column('role_id'),
            },
            created_at => $revoked_at,
        }
    );

    return {
        binding_id => $binding_id,
        revoked_at => $revoked_at,
    };
}

sub _record_audit {
    my ( $self, $input ) = @_;

    my $binding = $input->{binding};

    $self->schema->resultset('AuditLog')->create(
        {
            audit_id       => $self->id_service->uuid,
            action         => $input->{action},
            schema_version => $SCHEMA_VERSION,
            actor_id       => $input->{actor_user_id},
            target_type    => 'role_binding',
            target_id      => $binding->{binding_id},
            correlation_id => $self->id_service->uuid,
            previous_hash  => undef,
            record_hash    => q{},
            metadata       => {
                user_id       => $binding->{user_id},
                role_id       => $binding->{role_id},
                resource_type => $binding->{resource_type},
                resource_id   => $binding->{resource_id},
                space_id      => $binding->{space_id},
            },
            created_at => $input->{created_at},
        }
    );

    return;
}

1;
