package GPForum::Service::Moderation::ActionStore;

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

const my $STATE_VISIBLE => 'visible';
const my $STATE_HIDDEN  => 'hidden';
const my $STATE_LOCKED  => 'locked';
const my $TARGET_POST   => 'post';
const my $TARGET_THREAD => 'thread';
const my %LOCK_SQL_FOR  => (
    post => 'SELECT post_id FROM posts WHERE post_id = ? FOR UPDATE',
    thread =>
      'SELECT thread_id FROM threads WHERE thread_id = ? FOR UPDATE',
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

sub hide_post {
    my ( $self, $input ) = @_;

    my $timestamp = $self->clock->now_iso8601;

    return $self->_apply_action(
        {
            %{$input},
            action_type    => 'post.hidden',
            created_at     => $timestamp,
            expected_state => $STATE_HIDDEN,
            lock_kind      => $TARGET_POST,
            resultset      => 'Post',
            target_id      => $input->{post_id},
            target_type    => $TARGET_POST,
            updates        => {
                hidden_at        => $timestamp,
                moderation_state => $STATE_HIDDEN,
            },
        }
    );
}

sub restore_post {
    my ( $self, $input ) = @_;

    return $self->_apply_action(
        {
            %{$input},
            action_type    => 'post.restored',
            created_at     => $self->clock->now_iso8601,
            expected_state => $STATE_VISIBLE,
            lock_kind      => $TARGET_POST,
            resultset      => 'Post',
            target_id      => $input->{post_id},
            target_type    => $TARGET_POST,
            updates        => {
                hidden_at        => undef,
                moderation_state => $STATE_VISIBLE,
            },
        }
    );
}

sub lock_thread {
    my ( $self, $input ) = @_;

    my $timestamp = $self->clock->now_iso8601;

    return $self->_apply_action(
        {
            %{$input},
            action_type    => 'thread.locked',
            created_at     => $timestamp,
            expected_state => $STATE_LOCKED,
            lock_kind      => $TARGET_THREAD,
            resultset      => 'Thread',
            target_id      => $input->{thread_id},
            target_type    => $TARGET_THREAD,
            updates        => {
                locked_at        => $timestamp,
                moderation_state => $STATE_LOCKED,
            },
        }
    );
}

sub unlock_thread {
    my ( $self, $input ) = @_;

    return $self->_apply_action(
        {
            %{$input},
            action_type    => 'thread.unlocked',
            created_at     => $self->clock->now_iso8601,
            expected_state => $STATE_VISIBLE,
            lock_kind      => $TARGET_THREAD,
            resultset      => 'Thread',
            target_id      => $input->{thread_id},
            target_type    => $TARGET_THREAD,
            updates        => {
                locked_at        => undef,
                moderation_state => $STATE_VISIBLE,
            },
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

sub _apply_action {
    my ( $self, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            return $self->_apply_action_once($input);
        }
    );
}

sub _apply_action_once {
    my ( $self, $input ) = @_;

    $self->_lock_target($input);
    my $replayed = $self->_replayed_command($input);
    if ($replayed) {
        return $replayed;
    }

    my $target =
      $self->schema->resultset( $input->{resultset} )
      ->find( $input->{target_id} );
    if ( !$target ) {
        return;
    }

    return $self->_record_target_change( $target, $input );
}

sub _record_target_change {
    my ( $self, $target, $input ) = @_;

    my $previous_state = _column( $target, 'moderation_state' );
    my $idempotent =
      ( $previous_state || q{} ) eq $input->{expected_state} ? 1 : 0;
    if ( !$idempotent ) {
        $target->update( $input->{updates} );
    }

    return $self->_record_action(
        {
            actor_user_id  => $input->{actor_user_id},
            action_type    => $input->{action_type},
            command_id     => $input->{command_id},
            correlation_id => $input->{correlation_id},
            created_at     => $input->{created_at},
            metadata       => {
                command_id     => $input->{command_id},
                idempotent     => $idempotent,
                previous_state => $previous_state,
            },
            reason      => $input->{reason},
            target_id   => $input->{target_id},
            target_type => $input->{target_type},
        }
    );
}

sub _replayed_command {
    my ( $self, $input ) = @_;

    my $command_id = $input->{command_id};
    if ( !_has_text($command_id) ) {
        return;
    }

    my $existing = $self->_find_command_action($command_id);
    if ( !$existing ) {
        return;
    }

    return {
        action   => _action_hash($existing),
        ok       => 1,
        replayed => 1,
    };
}

sub _find_command_action {
    my ( $self, $command_id ) = @_;

    return $self->schema->resultset('ModerationAction')->search(
        { command_id => $command_id },
        { rows       => 1 },
    )->single;
}

sub _lock_target {
    my ( $self, $input ) = @_;

    my $dbh = _schema_dbh( $self->schema );
    if ( !$dbh ) {
        return;
    }

    $dbh->selectrow_array( $LOCK_SQL_FOR{ $input->{lock_kind} },
        undef, $input->{target_id} );

    return;
}

sub _record_action {
    my ( $self, $input ) = @_;

    my $action = {
        actor_user_id        => $input->{actor_user_id},
        action_type          => $input->{action_type},
        command_id           => $input->{command_id},
        created_at           => $input->{created_at},
        metadata             => $input->{metadata} || {},
        moderation_action_id => $self->id_service->uuid,
        reason               => $input->{reason},
        reversed_at          => undef,
        reversed_by_user_id  => undef,
        target_id            => $input->{target_id},
        target_type          => $input->{target_type},
    };
    my $created = eval {
        $self->schema->resultset('ModerationAction')->create($action);
        return $action;
    };
    my $error = $EVAL_ERROR;
    if ($created) {
        return $self->_recorded_action( $action, $input );
    }

    return $self->_action_after_conflict( $input, $error );
}

sub _recorded_action {
    my ( $self, $action, $input ) = @_;

    $self->_record_event_and_audit(
        {
            action         => $action,
            correlation_id => $input->{correlation_id},
        }
    );

    return { action => $action, ok => 1 };
}

sub _action_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        die $error;
    }

    my $existing = $self->_find_command_action( $input->{command_id} );
    if ( !$existing ) {
        die $error;
    }

    return {
        action   => _action_hash($existing),
        ok       => 1,
        replayed => 1,
    };
}

sub _action_hash {
    my ($row) = @_;

    if ( ref $row eq 'HASH' ) {
        return { %{$row} };
    }
    if ( $row && $row->can('data') ) {
        return { %{ $row->data } };
    }

    return {
        action_type          => _column( $row, 'action_type' ),
        actor_user_id        => _column( $row, 'actor_user_id' ),
        command_id           => _column( $row, 'command_id' ),
        created_at           => _column( $row, 'created_at' ),
        metadata             => _column( $row, 'metadata' ),
        moderation_action_id => _column( $row, 'moderation_action_id' ),
        reason               => _column( $row, 'reason' ),
        target_id            => _column( $row, 'target_id' ),
        target_type          => _column( $row, 'target_type' ),
    };
}

sub _has_text {
    my ($value) = @_;

    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

sub _schema_dbh {
    my ($schema) = @_;

    my $storage = eval { return $schema->storage; };
    if ( !$storage || !$storage->can('dbh') ) {
        return;
    }

    my $dbh = eval { return $storage->dbh; };
    return $dbh;
}

sub _record_event_and_audit {
    my ( $self, $input ) = @_;

    my $recorded = {
        action         => $input->{action},
        correlation_id => $input->{correlation_id} || $self->id_service->uuid,
    };
    $self->recorder->record_event(
        %{ $self->events->action_envelope($recorded) } );
    $self->recorder->record_audit(
        %{ $self->events->action_audit($recorded) } );

    return;
}

sub _record_reversal_event_and_audit {
    my ( $self, $input ) = @_;

    my $correlation_id = $self->id_service->uuid;
    $self->recorder->record_event(
        %{
            $self->events->reversal_envelope(
                {
                    %{$input}, correlation_id => $correlation_id,
                }
            )
        }
    );
    $self->recorder->record_audit(
        %{
            $self->events->reversal_audit(
                {
                    action         => $input->{action},
                    correlation_id => $correlation_id,
                    reason         => $input->{reason},
                    reversed_at    => $input->{reversed_at},
                    reversed_by    => $input->{reversed_by_user_id},
                }
            )
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
