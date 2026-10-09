# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Moderation::SuspensionStore;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Moderation::Event;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $ID_CONSTRAINT  => 'suspensions_pkey';
const my $STATUS_ACTIVE  => 'active';
const my $STATUS_DELETED => 'deleted';
const my $STATUS_SUSPEND => 'suspended';
const my %STATUS_DENIALS => (
    $STATUS_DELETED => 'user_deleted',
    $STATUS_SUSPEND => 'suspended',
);

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
__PACKAGE__->requires(qw(schema));
has events => sub { return GPForum::Service::Moderation::Event->new; };

sub create_suspension ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            return $self->_create_or_reuse($input);
        }
    );
}

# A member already under an active suspension keeps it. A minted id already
# stored is minted once more, unless a concurrent request suspended the
# member meanwhile.
sub _create_or_reuse ( $self, $input ) {
    my $user = $self->schema->resultset('User')->find( $input->{user_id} );
    if ( !$user ) {
        return undef;
    }

    my $active = $self->active_for_user( $input->{user_id} );
    if ($active) {
        return { ok => 1, suspension => _suspension_hash($active) };
    }

    my $insert = sub { return $self->_insert_suspension( $input, $user ); };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $insert );
    if ($created) {
        return $created;
    }

    my $conflict = GPForum::X::Conflict->caught($error);
    if ( !$conflict || !$conflict->on($ID_CONSTRAINT) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    $active = $self->active_for_user( $input->{user_id} );
    if ($active) {
        return { ok => 1, suspension => _suspension_hash($active) };
    }

    ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $insert );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _insert_suspension ( $self, $input, $user ) {
    my $timestamp       = $self->clock->now_iso8601;
    my $previous_status = _column( $user, 'status' );
    my $suspension      = {
        suspension_id => $self->id_service->uuid,
        user_id       => $input->{user_id},
        actor_user_id => $input->{actor_user_id},
        reason        => $input->{reason},
        valid_from    => $timestamp,
        valid_to      => $input->{valid_to},
        revoked_at    => undef,
        metadata      => {
            previous_status => $previous_status,
            source          => $input->{source} || 'moderation',
        },
    };
    $self->schema->resultset('Suspension')->create($suspension);
    $user->update(
        {
            status     => $STATUS_SUSPEND,
            updated_at => $timestamp,
        }
    );
    $self->_record_event_and_audit(
        {
            action         => 'user.suspended',
            actor_id       => $input->{actor_user_id},
            correlation_id => $input->{correlation_id},
            created_at     => $timestamp,
            metadata       => {
                previous_status => $previous_status,
                reason          => $input->{reason},
                suspension_id   => $suspension->{suspension_id},
            },
            payload => {
                reason        => $input->{reason},
                suspension_id => $suspension->{suspension_id},
                valid_from    => $timestamp,
                valid_to      => $input->{valid_to},
            },
            user_id => $input->{user_id},
        }
    );

    return { ok => 1, suspension => $suspension };
}

sub revoke_suspension ( $self, $suspension_id, $actor_user_id, $reason ) {
    return $self->schema->txn_do(
        sub {
            return $self->_revoke_in_txn(
                {
                    actor_user_id => $actor_user_id,
                    reason        => $reason,
                    suspension_id => $suspension_id,
                }
            );
        }
    );
}

# A suspension already revoked is answered as it stands, its member restored
# if an earlier attempt left them suspended.
sub _revoke_in_txn ( $self, $input ) {
    my $suspension =
      $self->schema->resultset('Suspension')->find( $input->{suspension_id} );
    if ( !$suspension ) {
        return undef;
    }
    my $user_id    = _column( $suspension, 'user_id' );
    my $revoked_at = _column( $suspension, 'revoked_at' );
    if ( defined $revoked_at ) {
        $self->_restore_user_if_needed( $user_id, $revoked_at );
        return {
            suspension_id => _column( $suspension, 'suspension_id' ),
            revoked_at    => $revoked_at,
        };
    }

    my $timestamp = $self->clock->now_iso8601;
    my $changes   = { revoked_at => $timestamp };
    $suspension->update($changes);
    $self->_restore_user_if_needed( $user_id, $timestamp );
    $self->_record_event_and_audit(
        {
            action         => 'user.suspension_revoked',
            actor_id       => $input->{actor_user_id},
            correlation_id => undef,
            created_at     => $timestamp,
            metadata       => {
                reason        => $input->{reason},
                suspension_id => $input->{suspension_id},
            },
            payload => {
                reason        => $input->{reason},
                suspension_id => $input->{suspension_id},
                revoked_at    => $timestamp,
            },
            user_id => $user_id,
        }
    );

    return { suspension_id => $input->{suspension_id}, %{$changes} };
}

sub _suspension_hash ($suspension) {
    return {
        suspension_id => _column( $suspension, 'suspension_id' ),
        user_id       => _column( $suspension, 'user_id' ),
        actor_user_id => _column( $suspension, 'actor_user_id' ),
        reason        => _column( $suspension, 'reason' ),
        valid_from    => _column( $suspension, 'valid_from' ),
        valid_to      => _column( $suspension, 'valid_to' ),
        revoked_at    => _column( $suspension, 'revoked_at' ),
        metadata      => _column( $suspension, 'metadata' ),
    };
}

sub active_for_user ( $self, $user_id ) {
    return undef if !defined $user_id || !length $user_id;

    my $search = $self->schema->resultset('Suspension')->search_rs(
        {
            user_id    => $user_id,
            revoked_at => undef,
        },
        {
            order_by =>
              [ { -desc => 'valid_from' }, { -desc => 'suspension_id' } ],
            rows => 10,
        }
    );

    for my $row ( _rows($search) ) {
        return $row if $self->_suspension_is_active($row);
    }

    return undef;
}

sub can_participate ( $self, $user_id ) {
    my $user = $self->schema->resultset('User')->find($user_id);
    return { ok => 0, reason => 'user_not_found' } if !$user;

    my $status = _column( $user, 'status' ) || $STATUS_ACTIVE;
    return { ok => 0, reason => $STATUS_DENIALS{$status} }
      if exists $STATUS_DENIALS{$status};

    my $active = $self->active_for_user($user_id);
    if ($active) {
        return {
            ok            => 0,
            reason        => 'suspended',
            suspension_id => _column( $active, 'suspension_id' ),
        };
    }

    return { ok => 1 };
}

sub _restore_user_if_needed ( $self, $user_id, $timestamp ) {
    if ( !defined $user_id || !length $user_id ) {
        return;
    }
    my $user = $self->schema->resultset('User')->find($user_id);
    if ( !$user || ( _column( $user, 'status' ) || q{} ) eq $STATUS_ACTIVE ) {
        return;
    }

    $user->update(
        {
            status     => $STATUS_ACTIVE,
            updated_at => $timestamp,
        }
    );

    return;
}

# Unrevoked, and open-ended or not yet past its end.
sub _suspension_is_active ( $self, $row ) {
    if ( !$row || defined _column( $row, 'revoked_at' ) ) {
        return 0;
    }

    my $valid_to = _column( $row, 'valid_to' );
    if ( !defined $valid_to || !length $valid_to ) {
        return 1;
    }

    return $valid_to ge $self->clock->now_iso8601 ? 1 : 0;
}

sub _record_event_and_audit ( $self, $input ) {
    my $recorded = {
        %{$input},
        correlation_id => $input->{correlation_id} || $self->id_service->uuid,
    };
    $self->recorder->record_event(
        %{ $self->events->suspension_envelope($recorded) } );
    $self->recorder->record_audit(
        %{ $self->events->suspension_audit($recorded) } );

    return;
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

1;

__END__

=head1 NAME

GPForum::Service::Moderation::SuspensionStore - Suspend and reinstate members, and say whether one may take part.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store =
      GPForum::Service::Moderation::SuspensionStore->new( schema => $schema );

    my $result = $store->create_suspension(
        {
            actor_user_id  => $moderator_id,
            correlation_id => $correlation_id,
            reason         => 'spam',
            user_id        => $user_id,
            valid_to       => '2026-11-01T00:00:00Z',
        }
    );

    my $gate = $store->can_participate($user_id);
    # { ok => 1 }, or { ok => 0, reason => 'suspended', ... }

    $store->revoke_suspension( $suspension_id, $moderator_id, 'appeal upheld' );

=head1 DESCRIPTION

Owns the C<suspensions> table and the user status that mirrors it. A
suspension sets the user's status to C<suspended> and records a
C<user.suspended> event and audit entry; a revocation stamps C<revoked_at>,
sets the user back to C<active> and records C<user.suspension_revoked>.
Each runs in one transaction with its event and audit rows, written through
L<GPForum::Infrastructure::EventRecorder> from the envelopes of
L<GPForum::Service::Moderation::Event>.

Suspending is idempotent: a user who already has an active suspension gets
that one back instead of a second row. A suspension is active while it is
not revoked and its C<valid_to> is empty or not yet past. An insert that
loses a race on the suspension id checks again for an active suspension and
otherwise retries once with a new id.

=head1 SUBROUTINES/METHODS

=head2 create_suspension

Takes a hash reference with C<user_id>, C<actor_user_id>, C<reason>, and
optional C<valid_to> (ISO 8601; none means open-ended), C<source> (kept in
the row's metadata, default C<moderation>) and C<correlation_id> (a new
uuid when absent). In a transaction, returns
C<< { ok => 1, suspension => \%suspension } >> with the new row, whose
metadata also keeps the user's previous status, or the user's active one.
Returns undef when the user does not exist.

=head2 revoke_suspension

Takes a suspension id, the acting user's id and a reason. In a transaction,
returns C<< { suspension_id, revoked_at } >>, or undef when there is no such
suspension. Revoking one that is already revoked records nothing new and
returns its original C<revoked_at>, but still sets the user back to
C<active> if they are not.

=head2 active_for_user

Takes a user id. Returns the newest active suspension row, looked for among
the user's ten most recent unrevoked suspensions by C<valid_from>; undef
when there is none or the id is empty.

=head2 can_participate

Takes a user id. Returns C<< { ok => 1 } >> when the user may take part.
Otherwise returns C<< { ok => 0, reason } >> with reason C<user_not_found>,
C<user_deleted> (status C<deleted>) or C<suspended> (status C<suspended>),
or C<suspended> together with C<suspension_id> when an active suspension
exists while the status says otherwise.

=head1 DIAGNOSTICS

A missing user or suspension is returned as undef, not thrown. An error
from the insert other than a collision on the suspension id, or a second
collision, is rethrown with C<croak>; other database errors propagate.
Either rolls the transaction back.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::Row>, L<GPForum::Infrastructure::EventRecorder>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::X::Conflict>,
L<GPForum::Infrastructure::Id>, L<GPForum::Service::Clock>,
L<GPForum::Service::Moderation::Event>.

Extends L<GPForum::Base>: built without C<schema> it throws
L<GPForum::X::Argument>.

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
