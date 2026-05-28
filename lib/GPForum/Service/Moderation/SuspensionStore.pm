package GPForum::Service::Moderation::SuspensionStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;
const my $STATUS_ACTIVE  => 'active';
const my $STATUS_DELETED => 'deleted';
const my $STATUS_SUSPEND => 'suspended';
const my $USER_AGGREGATE => 'user';
const my %STATUS_DENIALS => (
    $STATUS_DELETED => 'user_deleted',
    $STATUS_SUSPEND => 'suspended',
);

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has recorder   => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema => undef;

sub create_suspension {
    my ( $self, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            my $user =
              $self->schema->resultset('User')->find( $input->{user_id} );
            return if !$user;

            my $active = $self->active_for_user( $input->{user_id} );
            return { ok => 1, suspension => _suspension_hash($active) }
              if $active;

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
    );
}

sub revoke_suspension {
    my ( $self, $suspension_id, $actor_user_id, $reason ) = @_;

    return $self->schema->txn_do(
        sub {
            my $suspension =
              $self->schema->resultset('Suspension')->find($suspension_id);
            return if !$suspension;

            return _suspension_revoke_hash($suspension)
              if defined _column( $suspension, 'revoked_at' );

            my $timestamp = $self->clock->now_iso8601;
            my $user_id   = _column( $suspension, 'user_id' );
            my $changes   = { revoked_at => $timestamp };
            $suspension->update($changes);
            $self->_restore_user_if_needed( $user_id, $timestamp );
            $self->_record_event_and_audit(
                {
                    action         => 'user.suspension_revoked',
                    actor_id       => $actor_user_id,
                    correlation_id => undef,
                    created_at     => $timestamp,
                    metadata       => {
                        reason        => $reason,
                        suspension_id => $suspension_id,
                    },
                    payload => {
                        reason        => $reason,
                        suspension_id => $suspension_id,
                        revoked_at    => $timestamp,
                    },
                    user_id => $user_id,
                }
            );

            return { suspension_id => $suspension_id, %{$changes} };
        }
    );
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

    return if !defined $user_id || !length $user_id;

    my $user = $self->schema->resultset('User')->find($user_id);
    return if !$user;

    $user->update(
        {
            status     => $STATUS_ACTIVE,
            updated_at => $timestamp,
        }
    );

    return;
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

    my $correlation_id = $input->{correlation_id} || $self->id_service->uuid;
    $self->recorder->record_event(
        event_type        => $input->{action},
        aggregate_type    => $USER_AGGREGATE,
        aggregate_id      => $input->{user_id},
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $input->{actor_id},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   => join( q{:},
            $input->{action}, $input->{user_id}, $input->{created_at} ),
        payload   => $input->{payload},
        timestamp => $input->{created_at},
    );

    $self->recorder->record_audit(
        action         => $input->{action},
        schema_version => $SCHEMA_VERSION,
        actor_id       => $input->{actor_id},
        target_type    => $USER_AGGREGATE,
        target_id      => $input->{user_id},
        correlation_id => $correlation_id,
        metadata       => $input->{metadata},
        created_at     => $input->{created_at},
    );

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
