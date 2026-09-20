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

const my $COMMAND_CONSTRAINT => 'idx_moderation_actions_command_id';
const my $ID_CONSTRAINT      => 'moderation_actions_pkey';
const my $ROW_LIMIT_ONE      => 1;
const my $STATE_VISIBLE      => 'visible';
const my $STATE_HIDDEN       => 'hidden';
const my $STATE_LOCKED       => 'locked';
const my $TARGET_POST        => 'post';
const my $TARGET_THREAD      => 'thread';
const my %LOCK_SQL_FOR => (
    post   => 'SELECT post_id FROM posts WHERE post_id = ? FOR UPDATE',
    thread => 'SELECT thread_id FROM threads WHERE thread_id = ? FOR UPDATE',
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

sub hide_thread {
    my ( $self, $input ) = @_;

    my $timestamp = $self->clock->now_iso8601;

    return $self->_apply_action(
        {
            %{$input},
            action_type    => 'thread.hidden',
            created_at     => $timestamp,
            expected_state => $STATE_HIDDEN,
            lock_kind      => $TARGET_THREAD,
            resultset      => 'Thread',
            target_id      => $input->{thread_id},
            target_type    => $TARGET_THREAD,
            updates        => {
                hidden_at        => $timestamp,
                moderation_state => $STATE_HIDDEN,
            },
        }
    );
}

sub restore_thread {
    my ( $self, $input ) = @_;

    return $self->_apply_action(
        {
            %{$input},
            action_type    => 'thread.restored',
            created_at     => $self->clock->now_iso8601,
            expected_state => $STATE_VISIBLE,
            lock_kind      => $TARGET_THREAD,
            resultset      => 'Thread',
            target_id      => $input->{thread_id},
            target_type    => $TARGET_THREAD,
            updates        => {
                hidden_at        => undef,
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

    my $applied = $self->_applied_target_change( $target, $input );
    if ($applied) {
        return $applied;
    }

    return $self->_persist_target_change( $target, $input );
}

sub _applied_target_change {
    my ( $self, $target, $input ) = @_;

    if ( !_already_applied( $target, $input ) ) {
        return;
    }

    return $self->_replayed_target_action($input);
}

sub _already_applied {
    my ( $target, $input ) = @_;

    my $previous = _column( $target, 'moderation_state' ) || q{};

    return $previous eq $input->{expected_state} ? 1 : 0;
}

sub _persist_target_change {
    my ( $self, $target, $input ) = @_;

    my $previous_state = _column( $target, 'moderation_state' );
    my $idempotent     = _already_applied( $target, $input );
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

sub _replayed_target_action {
    my ( $self, $input ) = @_;

    my $existing = $self->_latest_target_action($input);
    if ( !$existing ) {
        return;
    }

    return {
        action     => _action_hash($existing),
        idempotent => 1,
        ok         => 1,
        skipped    => 1,
    };
}

sub _latest_target_action {
    my ( $self, $input ) = @_;

    return $self->schema->resultset('ModerationAction')->search(
        {
            action_type => $input->{action_type},
            reversed_at => undef,
            target_id   => $input->{target_id},
            target_type => $input->{target_type},
        },
        {
            order_by => { -desc => 'created_at' },
            rows     => 1,
        },
    )->single;
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

    return $self->_finish_leftover_action( $existing, $input );
}

sub _find_command_action {
    my ( $self, $command_id ) = @_;

    if ( !_has_text($command_id) ) {
        return;
    }

    return $self->schema->resultset('ModerationAction')
      ->search( { command_id => $command_id }, { rows => 1 }, )
      ->single;
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

    my $created = eval { return $self->_insert_action($input); };
    my $error   = $EVAL_ERROR;
    if ($created) {
        return $self->_recorded_action( $created, $input );
    }

    return $self->_action_after_conflict( $input, $error );
}

sub _insert_action {
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
    $self->schema->resultset('ModerationAction')->create($action);

    return $action;
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

sub _finish_leftover_action {
    my ( $self, $existing, $input ) = @_;

    if ( !$self->_action_event_exists($existing) ) {
        $self->_record_event_and_audit(
            {
                action         => $existing,
                correlation_id => $input->{correlation_id},
            }
        );
    }

    return _replayed_action($existing);
}

sub _action_event_exists {
    my ( $self, $existing ) = @_;

    my $search = $self->schema->resultset('EventLog')->search(
        {
            idempotency_key => join( q{:},
                _column( $existing, 'action_type' ),
                _column( $existing, 'target_type' ),
                _column( $existing, 'target_id' ),
                _column( $existing, 'moderation_action_id' ) ),
        },
        { rows => $ROW_LIMIT_ONE },
    );

    if ( $search->can('single') ) {
        return $search->single;
    }

    return;
}

sub _action_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_action_after_unique( $input, $error );
}

sub _action_after_unique {
    my ( $self, $input, $error ) = @_;

    if ( _action_id_conflict($error) ) {
        return $self->_action_after_id_conflict($input);
    }
    if ( _action_command_conflict($error) ) {
        return $self->_replay_command_action( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _action_after_id_conflict {
    my ( $self, $input ) = @_;

    my $existing = $self->_find_command_action( $input->{command_id} );
    if ($existing) {
        return $self->_finish_leftover_action( $existing, $input );
    }

    return $self->_retry_action_id($input);
}

sub _retry_action_id {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_insert_action($input); };
    if ($created) {
        return $self->_recorded_action( $created, $input );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _replay_command_action {
    my ( $self, $input, $error ) = @_;

    my $existing = $self->_find_command_action( $input->{command_id} );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_finish_leftover_action( $existing, $input );
}

sub _replayed_action {
    my ($existing) = @_;

    return {
        action   => _action_hash($existing),
        ok       => 1,
        replayed => 1,
    };
}

sub _action_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _action_command_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $COMMAND_CONSTRAINT ) >= 0 ? 1 : 0;
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
