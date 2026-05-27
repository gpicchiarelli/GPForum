package GPForum::Service::Moderation::ActionStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;
use GPForum::Service::Outbox::MessageBuilder;

our $VERSION = '0.001';

const my $STATE_VISIBLE  => 'visible';
const my $STATE_HIDDEN   => 'hidden';
const my $STATE_LOCKED   => 'locked';
const my $SCHEMA_VERSION => 1;
const my $TARGET_ACTION  => 'moderation_action';
const my $TARGET_POST    => 'post';
const my $TARGET_THREAD  => 'thread';

has clock          => sub { return GPForum::Service::Clock->new; };
has id_service     => sub { return GPForum::Service::Id->new; };
has outbox_builder => sub {
    my ($self) = @_;

    return GPForum::Service::Outbox::MessageBuilder->new(
        id_service => $self->id_service, );
};
has schema => undef;

sub hide_post {
    my ( $self, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            my $timestamp = $self->clock->now_iso8601;
            my $post =
              $self->schema->resultset('Post')->find( $input->{post_id} );
            return if !$post;

            my $previous_state = _column( $post, 'moderation_state' );
            my $idempotent =
              ( $previous_state || q{} ) eq $STATE_HIDDEN ? 1 : 0;
            if ( !$idempotent ) {
                $post->update(
                    {
                        moderation_state => $STATE_HIDDEN,
                        hidden_at        => $timestamp,
                    }
                );
            }

            return $self->_record_action(
                {
                    actor_user_id => $input->{actor_user_id},
                    action_type   => 'post.hidden',
                    target_type   => $TARGET_POST,
                    target_id     => $input->{post_id},
                    reason        => $input->{reason},
                    metadata      => {
                        idempotent     => $idempotent,
                        previous_state => $previous_state,
                    },
                    created_at     => $timestamp,
                    correlation_id => $input->{correlation_id},
                }
            );
        }
    );
}

sub restore_post {
    my ( $self, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            my $post =
              $self->schema->resultset('Post')->find( $input->{post_id} );
            return if !$post;

            my $previous_state = _column( $post, 'moderation_state' );
            my $idempotent =
              ( $previous_state || q{} ) eq $STATE_VISIBLE ? 1 : 0;
            if ( !$idempotent ) {
                $post->update(
                    {
                        moderation_state => $STATE_VISIBLE,
                        hidden_at        => undef,
                    }
                );
            }

            return $self->_record_action(
                {
                    actor_user_id => $input->{actor_user_id},
                    action_type   => 'post.restored',
                    target_type   => $TARGET_POST,
                    target_id     => $input->{post_id},
                    reason        => $input->{reason},
                    metadata      => {
                        idempotent     => $idempotent,
                        previous_state => $previous_state,
                    },
                    created_at     => $self->clock->now_iso8601,
                    correlation_id => $input->{correlation_id},
                }
            );
        }
    );
}

sub lock_thread {
    my ( $self, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            my $timestamp = $self->clock->now_iso8601;
            my $thread =
              $self->schema->resultset('Thread')->find( $input->{thread_id} );
            return if !$thread;

            my $previous_state = _column( $thread, 'moderation_state' );
            my $idempotent =
              ( $previous_state || q{} ) eq $STATE_LOCKED ? 1 : 0;
            if ( !$idempotent ) {
                $thread->update(
                    {
                        moderation_state => $STATE_LOCKED,
                        locked_at        => $timestamp,
                    }
                );
            }

            return $self->_record_action(
                {
                    actor_user_id => $input->{actor_user_id},
                    action_type   => 'thread.locked',
                    target_type   => $TARGET_THREAD,
                    target_id     => $input->{thread_id},
                    reason        => $input->{reason},
                    metadata      => {
                        idempotent     => $idempotent,
                        previous_state => $previous_state,
                    },
                    created_at     => $timestamp,
                    correlation_id => $input->{correlation_id},
                }
            );
        }
    );
}

sub unlock_thread {
    my ( $self, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            my $thread =
              $self->schema->resultset('Thread')->find( $input->{thread_id} );
            return if !$thread;

            my $previous_state = _column( $thread, 'moderation_state' );
            my $idempotent =
              ( $previous_state || q{} ) eq $STATE_VISIBLE ? 1 : 0;
            if ( !$idempotent ) {
                $thread->update(
                    {
                        moderation_state => $STATE_VISIBLE,
                        locked_at        => undef,
                    }
                );
            }

            return $self->_record_action(
                {
                    actor_user_id => $input->{actor_user_id},
                    action_type   => 'thread.unlocked',
                    target_type   => $TARGET_THREAD,
                    target_id     => $input->{thread_id},
                    reason        => $input->{reason},
                    metadata      => {
                        idempotent     => $idempotent,
                        previous_state => $previous_state,
                    },
                    created_at     => $self->clock->now_iso8601,
                    correlation_id => $input->{correlation_id},
                }
            );
        }
    );
}

sub reverse_action {
    my ( $self, $action_id, $reversed_by_user_id, $reason ) = @_;

    return $self->schema->txn_do(
        sub {
            my $timestamp = $self->clock->now_iso8601;
            my $action =
              $self->schema->resultset('ModerationAction')->find($action_id);
            return if !$action;

            my $existing_reversed_at = _column( $action, 'reversed_at' );
            return _reversal_hash($action) if defined $existing_reversed_at;

            my $changes = {
                reversed_at         => $timestamp,
                reversed_by_user_id => $reversed_by_user_id,
            };
            $action->update($changes);
            $self->_record_reversal_event_and_audit(
                {
                    action              => $action,
                    action_id           => $action_id,
                    reason              => $reason,
                    reversed_by_user_id => $reversed_by_user_id,
                    reversed_at         => $timestamp,
                }
            );

            return { moderation_action_id => $action_id, %{$changes} };
        }
    );
}

sub _reversal_hash {
    my ($action) = @_;

    return {
        moderation_action_id => _column( $action, 'moderation_action_id' ),
        reversed_at          => _column( $action, 'reversed_at' ),
        reversed_by_user_id  => _column( $action, 'reversed_by_user_id' ),
    };
}

sub _record_action {
    my ( $self, $input ) = @_;

    my $action = {
        moderation_action_id => $self->id_service->uuid,
        actor_user_id        => $input->{actor_user_id},
        action_type          => $input->{action_type},
        target_type          => $input->{target_type},
        target_id            => $input->{target_id},
        reason               => $input->{reason},
        metadata             => $input->{metadata} || {},
        created_at           => $input->{created_at},
        reversed_at          => undef,
        reversed_by_user_id  => undef,
    };
    $self->schema->resultset('ModerationAction')->create($action);
    $self->_record_event_and_audit(
        {
            action         => $action,
            correlation_id => $input->{correlation_id},
        }
    );

    return { ok => 1, action => $action };
}

sub _record_event_and_audit {
    my ( $self, $input ) = @_;

    my $action         = $input->{action};
    my $correlation_id = $input->{correlation_id} || $self->id_service->uuid;
    my $event          = {
        event_id          => $self->id_service->uuid,
        event_type        => $action->{action_type},
        schema_version    => $SCHEMA_VERSION,
        aggregate_type    => $action->{target_type},
        aggregate_id      => $action->{target_id},
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $action->{actor_user_id},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   => join( q{:},
            $action->{action_type}, $action->{target_type},
            $action->{target_id},   $action->{moderation_action_id} ),
        payload => {
            moderation_action_id => $action->{moderation_action_id},
            target_type          => $action->{target_type},
            target_id            => $action->{target_id},
            reason               => $action->{reason},
            metadata             => $action->{metadata},
        },
        metadata   => {},
        created_at => $action->{created_at},
    };

    $self->schema->resultset('EventLog')->create($event);
    $self->schema->resultset('OutboxMessage')
      ->create( $self->outbox_builder->for_event($event) );
    $self->_record_audit(
        {
            action         => $action,
            correlation_id => $correlation_id,
        }
    );

    return;
}

sub _record_reversal_event_and_audit {
    my ( $self, $input ) = @_;

    my $action         = $input->{action};
    my $correlation_id = $self->id_service->uuid;
    my $event          = {
        event_id          => $self->id_service->uuid,
        event_type        => 'moderation_action.reversed',
        schema_version    => $SCHEMA_VERSION,
        aggregate_type    => $TARGET_ACTION,
        aggregate_id      => $input->{action_id},
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $input->{reversed_by_user_id},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   =>
          join( q{:}, 'moderation_action.reversed', $input->{action_id} ),
        payload => {
            moderation_action_id => $input->{action_id},
            reversed_by_user_id  => $input->{reversed_by_user_id},
            reversed_at          => $input->{reversed_at},
            original_action_type => _column( $action, 'action_type' ),
            target_type          => _column( $action, 'target_type' ),
            target_id            => _column( $action, 'target_id' ),
            reason               => $input->{reason},
        },
        metadata   => {},
        created_at => $input->{reversed_at},
    };

    $self->schema->resultset('EventLog')->create($event);
    $self->schema->resultset('OutboxMessage')
      ->create( $self->outbox_builder->for_event($event) );
    $self->_record_reversal_audit(
        {
            action         => $action,
            correlation_id => $correlation_id,
            reversed_at    => $input->{reversed_at},
            reversed_by    => $input->{reversed_by_user_id},
            reason         => $input->{reason},
        }
    );

    return;
}

sub _record_audit {
    my ( $self, $input ) = @_;

    my $action = $input->{action};

    $self->schema->resultset('AuditLog')->create(
        {
            audit_id       => $self->id_service->uuid,
            action         => $action->{action_type},
            schema_version => $SCHEMA_VERSION,
            actor_id       => $action->{actor_user_id},
            target_type    => $action->{target_type},
            target_id      => $action->{target_id},
            correlation_id => $input->{correlation_id},
            previous_hash  => undef,
            record_hash    => q{},
            metadata       => {
                reason               => $action->{reason},
                moderation_action_id => $action->{moderation_action_id},
            },
            created_at => $action->{created_at},
        }
    );

    return;
}

sub _record_reversal_audit {
    my ( $self, $input ) = @_;

    my $action = $input->{action};

    $self->schema->resultset('AuditLog')->create(
        {
            audit_id       => $self->id_service->uuid,
            action         => 'moderation_action.reversed',
            schema_version => $SCHEMA_VERSION,
            actor_id       => $input->{reversed_by},
            target_type    => _column( $action, 'target_type' ),
            target_id      => _column( $action, 'target_id' ),
            correlation_id => $input->{correlation_id},
            previous_hash  => undef,
            record_hash    => q{},
            metadata       => {
                moderation_action_id =>
                  _column( $action, 'moderation_action_id' ),
                original_action_type => _column( $action, 'action_type' ),
                reason               => $input->{reason},
            },
            created_at => $input->{reversed_at},
        }
    );

    return;
}

sub _column {
    my ( $row, $name ) = @_;

    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    return;
}

1;
