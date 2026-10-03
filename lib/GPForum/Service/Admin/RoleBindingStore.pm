# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::RoleBindingStore;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

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
    my $binding = $self->_locked_binding($binding_id);
    return undef if !$binding;

    # Checked under the row lock, so a revocation that committed while this
    # one waited is reported here rather than stamped and audited again.
    return {
        binding_id => $binding_id,
        idempotent => 1,
        revoked_at => $binding->get_column('revoked_at'),
      }
      if defined $binding->get_column('revoked_at');

    my $revoked_at = $self->clock->now_iso8601;
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

# SELECT ... FOR UPDATE: a second revocation of the same binding waits here
# until the first commits, then reads the revoked_at it wrote. Read without
# the lock, both saw the binding active; the later one overwrote revoked_at
# and recorded a second audit row.
sub _locked_binding ( $self, $binding_id ) {
    return $self->schema->resultset('RoleBinding')
      ->find( $binding_id, { for => 'update' } );
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

    return undef;
}

sub _binding_hash ($binding) {
    return undef if !$binding;

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
        return undef;
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

    return undef;
}

sub _record_audit ( $self, $input ) {
    $self->recorder->record_audit( %{ $self->events->binding_audit($input) } );

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Admin::RoleBindingStore - Grants and revokes role bindings, with their audit rows.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store =
      GPForum::Service::Admin::RoleBindingStore->new( schema => $schema );
    my $bound = $store->bind_role(
        {
            actor_user_id => $admin_id,
            user_id       => $user_id,
            role_id       => $role_id,
            resource_type => 'global',
            resource_id   => undef,
            space_id      => undef,
        }
    );
    $store->revoke_binding( $bound->{binding}{binding_id}, $admin_id );

=head1 DESCRIPTION

A role binding gives a user a role over a scope: a resource type, optionally
one resource, optionally one space. This store writes those rows for the
console (through L<GPForum::Service::Admin::Workflow>) and for the first
administrator (through L<GPForum::Service::Admin::Bootstrapper>), and records
a C<role_binding.created> or C<role_binding.revoked> audit row with each.

Granting is idempotent: the same user, role and scope that already hold an
active binding get that binding back. The database's unique index on active
bindings decides a race between two grants, and the loser returns the
winner's row rather than an error. A binding found without its audit row --
one written before a crash, or by older code -- has the row written when it
is next granted. Revoking stamps C<revoked_at> under the binding's row lock;
the row is kept.

=head1 SUBROUTINES/METHODS

=head2 bind_role

Takes a hash reference with C<user_id>, C<role_id>, C<resource_type>,
C<resource_id>, C<space_id> and C<actor_user_id>; the scope columns are
matched as given, so C<undef> means "none". Runs inside
C<< $schema->txn_do >> when the schema has one.

Returns C<< { ok => 1, binding => \%binding } >> for a new binding, or
C<< { ok => 1, idempotent => 1, binding => \%binding } >> when an active one
already existed or a concurrent grant made it first. C<%binding> holds
C<binding_id>, C<user_id>, C<role_id>, C<resource_type>, C<resource_id>,
C<space_id>, C<created_by_user_id>, C<created_at> and C<revoked_at>.

The insert runs under a savepoint. When it collides on the primary key the
store looks again for an active binding and otherwise retries once with a new
id; a second failure is rethrown.

=head2 revoke_binding

Takes a binding id and the acting user's id. Returns C<undef> when there is
no such binding, C<< { binding_id, idempotent => 1, revoked_at } >> with the
earlier time when it was already revoked, and
C<< { binding_id, revoked_at } >> when this call revoked it and wrote the
audit row.

Runs inside C<< $schema->txn_do >> when the schema has one, and reads the
binding with C<SELECT ... FOR UPDATE>. Two revocations of one binding are
therefore serialised: the second waits for the first to commit, then finds
C<revoked_at> set and returns the idempotent answer, so the binding keeps
the first revocation's time and has one C<role_binding.revoked> audit row.

=head1 DIAGNOSTICS

Rethrows any insert error that is not a unique conflict on
C<role_bindings_pkey> or C<idx_role_bindings_active_unique>, and a conflict
on the active index when no active binding can then be found. Other
database errors propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::EventRecorder>,
L<GPForum::Infrastructure::UniqueConflict>,
L<GPForum::Infrastructure::Row>,
L<GPForum::Infrastructure::Id>,
L<GPForum::Service::Admin::Event>,
L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

No input is validated here; L<GPForum::Service::Admin::Workflow> checks the
required fields first.

The row lock that serialises revocations lasts as long as the transaction
around it. L<GPForum::Schema> always has C<txn_do>; through a schema
without one, as some in-memory test doubles are, each statement would
commit on its own and the lock would be released as soon as it was taken.

Completing a lost C<role_binding.created> row is not serialised: the active
binding is read without a lock and its audit row looked for before one is
written, so two grants that find the same binding without its row at the
same moment can both write it.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
