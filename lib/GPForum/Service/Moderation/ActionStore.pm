# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Moderation::ActionStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Moderation::Event;

our $VERSION = '0.001';

const my $COMMAND_CONSTRAINT => 'idx_moderation_actions_command_id';
const my $ID_CONSTRAINT      => 'moderation_actions_pkey';
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
has events => sub { return GPForum::Service::Moderation::Event->new; };

sub hide_post ( $self, $input ) {
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

sub restore_post ( $self, $input ) {
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

sub lock_thread ( $self, $input ) {
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

sub unlock_thread ( $self, $input ) {
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

sub hide_thread ( $self, $input ) {
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

sub restore_thread ( $self, $input ) {
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

sub reverse_action ( $self, $action_id, $reversed_by_user_id, $reason ) {
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

sub _reversal_hash ($action) {
    return {
        moderation_action_id => _column( $action, 'moderation_action_id' ),
        reversed_at          => _column( $action, 'reversed_at' ),
        reversed_by_user_id  => _column( $action, 'reversed_by_user_id' ),
    };
}

sub _apply_action ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            return $self->_apply_action_once($input);
        }
    );
}

sub _apply_action_once ( $self, $input ) {
    $self->_lock_target($input);
    my $replayed = $self->_replayed_command($input);
    if ($replayed) {
        return $replayed;
    }

    my $target =
      $self->schema->resultset( $input->{resultset} )
      ->find( $input->{target_id} );
    if ( !$target ) {
        my $undefined;
        return $undefined;
    }

    return $self->_record_target_change( $target, $input );
}

sub _record_target_change ( $self, $target, $input ) {
    my $applied = $self->_applied_target_change( $target, $input );
    if ($applied) {
        return $applied;
    }

    return $self->_persist_target_change( $target, $input );
}

sub _applied_target_change ( $self, $target, $input ) {
    if ( !_already_applied( $target, $input ) ) {
        my $undefined;
        return $undefined;
    }

    return $self->_replayed_target_action($input);
}

sub _already_applied ( $target, $input ) {
    my $previous = _column( $target, 'moderation_state' ) || q{};

    return $previous eq $input->{expected_state} ? 1 : 0;
}

sub _persist_target_change ( $self, $target, $input ) {
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

sub _replayed_target_action ( $self, $input ) {
    my $existing = $self->_latest_target_action($input);
    if ( !$existing ) {
        my $undefined;
        return $undefined;
    }

    return {
        action     => _action_hash($existing),
        idempotent => 1,
        ok         => 1,
        skipped    => 1,
    };
}

sub _latest_target_action ( $self, $input ) {
    return $self->schema->resultset('ModerationAction')->search_rs(
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

sub _replayed_command ( $self, $input ) {
    my $undefined;

    my $command_id = $input->{command_id};
    if ( !_has_text($command_id) ) {
        return $undefined;
    }

    my $existing = $self->_find_command_action($command_id);
    if ( !$existing ) {
        return $undefined;
    }

    return $self->_finish_leftover_action( $existing, $input );
}

sub _find_command_action ( $self, $command_id ) {
    if ( !_has_text($command_id) ) {
        my $undefined;
        return $undefined;
    }

    return $self->schema->resultset('ModerationAction')
      ->search_rs( { command_id => $command_id }, { rows => 1 }, )
      ->single;
}

sub _lock_target ( $self, $input ) {
    my $dbh = _schema_dbh( $self->schema );
    if ( !$dbh ) {
        return;
    }

    $dbh->selectrow_array( $LOCK_SQL_FOR{ $input->{lock_kind} },
        undef, $input->{target_id} );

    return;
}

sub _record_action ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_action($input); },
      );
    if ($created) {
        return $self->_recorded_action( $created, $input );
    }

    return $self->_action_after_conflict( $input, $error );
}

sub _insert_action ( $self, $input ) {
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

sub _recorded_action ( $self, $action, $input ) {
    $self->_record_event_and_audit(
        {
            action         => $action,
            correlation_id => $input->{correlation_id},
        }
    );

    return { action => $action, ok => 1 };
}

sub _finish_leftover_action ( $self, $existing, $input ) {
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

sub _action_event_exists ( $self, $existing ) {
    return $self->recorder->event_recorded(
        join q{:},
        map { _column( $existing, $_ ) }
          qw(action_type target_type target_id moderation_action_id)
    );
}

sub _action_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_action_after_unique( $input, $error );
}

sub _action_after_unique ( $self, $input, $error ) {
    if ( _action_id_conflict($error) ) {
        return $self->_action_after_id_conflict($input);
    }
    if ( _action_command_conflict($error) ) {
        return $self->_replay_command_action( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _action_after_id_conflict ( $self, $input ) {
    my $existing = $self->_find_command_action( $input->{command_id} );
    if ($existing) {
        return $self->_finish_leftover_action( $existing, $input );
    }

    return $self->_retry_action_id($input);
}

sub _retry_action_id ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_action($input); },
      );
    if ($created) {
        return $self->_recorded_action( $created, $input );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _replay_command_action ( $self, $input, $error ) {
    my $existing = $self->_find_command_action( $input->{command_id} );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_finish_leftover_action( $existing, $input );
}

sub _replayed_action ($existing) {
    return {
        action   => _action_hash($existing),
        ok       => 1,
        replayed => 1,
    };
}

sub _action_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _action_command_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $COMMAND_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _action_hash ($row) {
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

sub _has_text ($value) {
    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

sub _schema_dbh ($schema) {
    my $storage = eval { return $schema->storage; };
    if ( !$storage || !$storage->can('dbh') ) {
        my $undefined;
        return $undefined;
    }

    my $dbh = eval { return $storage->dbh; };
    return $dbh;
}

sub _record_event_and_audit ( $self, $input ) {
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

sub _record_reversal_event_and_audit ( $self, $input ) {
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

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

1;

__END__

=head1 NAME

GPForum::Service::Moderation::ActionStore - Hide, restore, lock and unlock content and record each moderation action once.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $actions = GPForum::Service::Moderation::ActionStore->new(
        schema => $schema,
    );
    my $result = $actions->hide_post(
        {
            actor_user_id  => $moderator_id,
            command_id     => $command_id,
            correlation_id => $correlation_id,
            post_id        => $post_id,
            reason         => 'spam',
        }
    );
    # { ok => 1, action => {...} }, with replayed or skipped on a repeat,
    # or undef when the post does not exist

    $actions->lock_thread(
        {
            actor_user_id => $moderator_id,
            command_id    => $other_command_id,
            reason        => 'off topic',
            thread_id     => $thread_id,
        }
    );
    $actions->reverse_action( $action_id, $moderator_id, 'appeal upheld' );

=head1 DESCRIPTION

The write side of moderation for L<GPForum::Service::Moderation::Workflow>.
Each action changes the target's C<moderation_state> (and C<hidden_at> or
C<locked_at>), inserts a C<moderation_actions> row and records the matching
event and audit entry through L<GPForum::Infrastructure::EventRecorder>, with
shapes from L<GPForum::Service::Moderation::Event>; all of it in one
transaction, after the target row has been locked with
C<SELECT ... FOR UPDATE> so two moderators acting on the same post or thread
take turns.

Every action is safe to repeat:

=over 4

=item * A command id that already has an action row is a replay: nothing
changes, the stored action comes back with C<< replayed => 1 >>, and the
action's event and audit are written first if an earlier attempt left the
row without them.

=item * A target already in the requested state is not updated. When an
unreversed action of the same type exists for it, that action comes back
with C<< skipped => 1 >> and C<< idempotent => 1 >>; otherwise a new action
is recorded with C<< idempotent => 1 >> in its metadata.

=item * A unique conflict on the command id (a concurrent request with the
same command) replays the row that won; a conflict on the generated action
id is retried once with a fresh id. Inserts run under savepoints through
L<GPForum::Infrastructure::UniqueConflict>.

=back

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> is required; C<clock>, C<id_service>,
C<recorder> and C<events> have defaults.

=head2 hide_post

Takes a hash reference with C<post_id>, C<actor_user_id>, C<reason> and the
optional C<command_id> and C<correlation_id> (a fresh one for the event
when absent). Sets the post's state to C<hidden> and stamps C<hidden_at>,
and records a C<post.hidden> action. Returns C<< { ok => 1, action => \%action } >>,
the replay or skip results described above, or C<undef> when the post does
not exist. The action hash holds C<moderation_action_id>, C<action_type>,
C<target_type>, C<target_id>, C<actor_user_id>, C<command_id>, C<reason>,
C<created_at> and C<metadata> (C<command_id>, C<idempotent>,
C<previous_state>).

=head2 restore_post

As L</hide_post>, setting the post's state to C<visible>, clearing
C<hidden_at> and recording C<post.restored>.

=head2 hide_thread

As L</hide_post> for a thread, keyed by C<thread_id>: state C<hidden>,
C<hidden_at> stamped, action C<thread.hidden>.

=head2 restore_thread

As L</hide_thread>, setting the state to C<visible>, clearing C<hidden_at>
and recording C<thread.restored>.

=head2 lock_thread

As L</hide_thread>, setting the state to C<locked>, stamping C<locked_at>
and recording C<thread.locked>.

=head2 unlock_thread

As L</hide_thread>, setting the state to C<visible>, clearing C<locked_at>
and recording C<thread.unlocked>.

=head2 reverse_action

Takes an action id, the id of the user reversing it and a reason. In a
transaction, stamps the action's C<reversed_at> and C<reversed_by_user_id>
and records a C<moderation_action.reversed> event and its audit entry.
Returns C<< { moderation_action_id, reversed_at, reversed_by_user_id } >>.
An action already reversed returns its existing reversal and writes
nothing; an unknown action id returns nothing. The target's state is not
changed here.

=head1 DIAGNOSTICS

A missing target returns C<undef> and a missing action an empty return;
neither is thrown. Database errors other than the handled unique conflicts
are rethrown and the transaction rolls back.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::EventRecorder>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Infrastructure::Row>,
L<GPForum::Infrastructure::Id>, L<GPForum::Service::Clock>,
L<GPForum::Service::Moderation::Event>.

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
