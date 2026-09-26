# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::RoleBindingStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Admin::Event;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $ROW_LIMIT_ONE     => 1;
const my $ID_CONSTRAINT     => 'role_bindings_pkey';
const my $ACTIVE_CONSTRAINT => 'idx_role_bindings_active_unique';

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
has events => sub { return GPForum::Service::Admin::Event->new; };

sub bind_role ( $self, $input ) {
    return $self->_txn( sub { return $self->_bind_role_once($input); } );
}

sub _txn ( $self, $code ) {
    return $self->schema->can('txn_do')
      ? $self->schema->txn_do($code)
      : $code->();
}

sub _bind_role_once ( $self, $input ) {
    my $existing = $self->_active_binding($input);
    if ($existing) {
        return $self->_finish_leftover_binding( $existing, $input );
    }

    return $self->_insert_or_reuse_binding($input);
}

sub _insert_or_reuse_binding ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_binding($input); },
      );
    if ($error) {
        return $self->_binding_after_conflict( $input, $error );
    }

    return $created;
}

sub _binding_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_binding_after_unique( $input, $error );
}

sub _binding_after_unique ( $self, $input, $error ) {
    if ( _binding_id_conflict($error) ) {
        return $self->_binding_after_id_conflict($input);
    }
    if ( _active_binding_conflict($error) ) {
        return $self->_reuse_binding_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _binding_after_id_conflict ( $self, $input ) {
    my $existing = $self->_active_binding($input);
    if ($existing) {
        return $self->_finish_leftover_binding( $existing, $input );
    }

    return $self->_retry_binding_id($input);
}

sub _retry_binding_id ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_binding($input); },
      );
    if ($error) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $created;
}

sub _reuse_binding_row ( $self, $input, $error ) {
    my $existing = $self->_active_binding($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_finish_leftover_binding( $existing, $input );
}

sub _binding_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _active_binding_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ACTIVE_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_binding ( $self, $input ) {
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

sub _idempotent_binding ($existing) {
    return {
        ok         => 1,
        idempotent => 1,
        binding    => _binding_hash($existing),
    };
}

sub revoke_binding ( $self, $binding_id, $actor_user_id ) {
    return $self->_txn(
        sub {
            return $self->_revoke_binding_once( $binding_id, $actor_user_id );
        }
    );
}

sub _revoke_binding_once ( $self, $binding_id, $actor_user_id ) {
    my $revoked_at = $self->clock->now_iso8601;
    my $binding    = $self->schema->resultset('RoleBinding')->find($binding_id);
    my $undefined;
    return $undefined if !$binding;

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

sub _active_binding ( $self, $input ) {
    my $search = $self->schema->resultset('RoleBinding')->search_rs(
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

    my $undefined;
    return $undefined;
}

sub _binding_hash ($binding) {
    my $undefined;
    return $undefined if !$binding;

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

sub _column ( $row, $column ) {
    return GPForum::Infrastructure::Row->column( $row, $column );
}

sub _finish_leftover_binding ( $self, $existing, $input ) {
    $self->_ensure_binding_audit( $existing, $input );

    return _idempotent_binding($existing);
}

sub _ensure_binding_audit ( $self, $existing, $input ) {
    if ( $self->_binding_audit_exists($existing) ) {
        my $undefined;
        return $undefined;
    }

    return $self->_record_audit(
        {
            action        => 'role_binding.created',
            actor_user_id => $input->{actor_user_id},
            binding       => $existing,
            created_at    => _column( $existing, 'created_at' )
              || $self->clock->now_iso8601,
        }
    );
}

sub _binding_audit_exists ( $self, $existing ) {
    my $search = $self->schema->resultset('AuditLog')->search_rs(
        {
            action    => 'role_binding.created',
            target_id => _column( $existing, 'binding_id' ),
        },
        { rows => $ROW_LIMIT_ONE },
    );

    if ( $search->can('single') ) {
        return $search->single;
    }

    my $undefined;
    return $undefined;
}

sub _record_audit ( $self, $input ) {
    $self->recorder->record_audit( %{ $self->events->binding_audit($input) } );

    return;
}

1;
