package GPForum::Service::Moderation::SuspensionStore;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Moderation::Event;

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
has events => sub { return GPForum::Service::Moderation::Event->new; };

sub create_suspension {
    my ( $self, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            return $self->_create_or_reuse($input);
        }
    );
}

sub _create_or_reuse {
    my ( $self, $input ) = @_;

    my $user = $self->schema->resultset('User')->find( $input->{user_id} );
    if ( !$user ) {
        return;
    }

    my $active = $self->active_for_user( $input->{user_id} );
    if ($active) {
        return { ok => 1, suspension => _suspension_hash($active) };
    }

    return $self->_insert_or_retry( $input, $user );
}

sub _insert_or_retry {
    my ( $self, $input, $user ) = @_;

    my $created = eval { return $self->_insert_suspension( $input, $user ); };
    if ($created) {
        return $created;
    }

    return $self->_suspension_after_conflict( $input, $user, $EVAL_ERROR );
}

sub _insert_suspension {
    my ( $self, $input, $user ) = @_;

    my $timestamp  = $self->clock->now_iso8601;
    my $suspension = $self->_suspension_row( $input, $user, $timestamp );
    $self->schema->resultset('Suspension')->create($suspension);
    $user->update(
        {
            status     => $STATUS_SUSPEND,
            updated_at => $timestamp,
        }
    );
    $self->_record_event_and_audit(
        $self->_suspension_event( $input, $suspension, $timestamp ) );

    return { ok => 1, suspension => $suspension };
}

sub _suspension_row {
    my ( $self, $input, $user, $timestamp ) = @_;

    my $previous_status = _column( $user, 'status' );

    return {
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
}

sub _suspension_event {
    my ( $self, $input, $suspension, $timestamp ) = @_;

    my $previous_status = $suspension->{metadata}{previous_status};

    return {
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
    };
}

sub _suspension_after_conflict {
    my ( $self, $input, $user, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( index( $error, $ID_CONSTRAINT ) < 0 ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_suspension_id( $input, $user );
}

sub _retry_suspension_id {
    my ( $self, $input, $user ) = @_;

    my $active = $self->active_for_user( $input->{user_id} );
    if ($active) {
        return { ok => 1, suspension => _suspension_hash($active) };
    }

    my $created = eval { return $self->_insert_suspension( $input, $user ); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub revoke_suspension {
    my ( $self, $suspension_id, $actor_user_id, $reason ) = @_;

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

sub _revoke_in_txn {
    my ( $self, $input ) = @_;

    my $suspension =
      $self->schema->resultset('Suspension')->find( $input->{suspension_id} );
    if ( !$suspension ) {
        return;
    }
    if ( defined _column( $suspension, 'revoked_at' ) ) {
        return $self->_already_revoked($suspension);
    }

    return $self->_revoke_open( $suspension, $input );
}

sub _already_revoked {
    my ( $self, $suspension ) = @_;

    $self->_restore_user_if_needed(
        _column( $suspension, 'user_id' ),
        _column( $suspension, 'revoked_at' ),
    );

    return _suspension_revoke_hash($suspension);
}

sub _revoke_open {
    my ( $self, $suspension, $input ) = @_;

    my $timestamp = $self->clock->now_iso8601;
    my $user_id   = _column( $suspension, 'user_id' );
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

sub _suspension_hash {
    my ($suspension) = @_;

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

sub _suspension_revoke_hash {
    my ($suspension) = @_;

    return {
        suspension_id => _column( $suspension, 'suspension_id' ),
        revoked_at    => _column( $suspension, 'revoked_at' ),
    };
}

sub active_for_user {
    my ( $self, $user_id ) = @_;

    return if !defined $user_id || !length $user_id;

    my $search = $self->schema->resultset('Suspension')->search(
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

    return;
}

sub can_participate {
    my ( $self, $user_id ) = @_;

    my $user = $self->schema->resultset('User')->find($user_id);
    return { ok => 0, reason => 'user_not_found' } if !$user;

    my $status = _column( $user, 'status' ) || $STATUS_ACTIVE;
    return { ok => 0, reason => $STATUS_DENIALS{$status} }
      if exists $STATUS_DENIALS{$status};

    my $active = $self->active_for_user($user_id);
    return _active_denial($active) if $active;

    return { ok => 1 };
}

sub _restore_user_if_needed {
    my ( $self, $user_id, $timestamp ) = @_;

    my $user = $self->_user_to_restore($user_id);
    if ( !$user ) {
        return;
    }
    if ( _already_active($user) ) {
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

sub _user_to_restore {
    my ( $self, $user_id ) = @_;

    if ( !defined $user_id ) {
        return;
    }
    if ( !length $user_id ) {
        return;
    }

    return $self->schema->resultset('User')->find($user_id);
}

sub _already_active {
    my ($user) = @_;

    my $held = _column( $user, 'status' ) || q{};
    if ( $held eq $STATUS_ACTIVE ) {
        return 1;
    }

    return 0;
}

sub _suspension_is_active {
    my ( $self, $row ) = @_;

    return 0 if !$row;
    return 0 if defined _column( $row, 'revoked_at' );

    return $self->_valid_to_is_active( _column( $row, 'valid_to' ) );
}

sub _valid_to_is_active {
    my ( $self, $valid_to ) = @_;

    return 1 if !defined $valid_to || !length $valid_to;
    return $valid_to ge $self->clock->now_iso8601 ? 1 : 0;
}

sub _active_denial {
    my ($active) = @_;

    return {
        ok            => 0,
        reason        => 'suspended',
        suspension_id => _column( $active, 'suspension_id' ),
    };
}

sub _record_event_and_audit {
    my ( $self, $input ) = @_;

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

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _column {
    my ( $row, $name ) = @_;

    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    return;
}

1;
