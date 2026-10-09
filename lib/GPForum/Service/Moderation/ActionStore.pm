# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Moderation::ActionStore;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::Storage;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Moderation::Event;
use GPForum::X::Conflict;

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
__PACKAGE__->requires(qw(schema));
has events => sub { return GPForum::Service::Moderation::Event->new; };

sub hide_post ( $self, $input ) {
    my $timestamp = $self->clock->now_iso8601;

    return $self->_apply_action(
        {
            %{$input},
            action_type => 'post.hidden',
            applied     => \&_is_hidden,
            created_at  => $timestamp,
            lock_kind   => $TARGET_POST,
            resultset   => 'Post',
            target_id   => $input->{post_id},
            target_type => $TARGET_POST,
            updates     => {
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
            action_type => 'post.restored',
            applied     => sub ($post) {
                return _state($post) eq $STATE_VISIBLE ? 1 : 0;
            },
            created_at  => $self->clock->now_iso8601,
            lock_kind   => $TARGET_POST,
            resultset   => 'Post',
            target_id   => $input->{post_id},
            target_type => $TARGET_POST,
            updates     => {
                hidden_at        => undef,
                moderation_state => $STATE_VISIBLE,
            },
        }
    );
}

# A thread keeps two facts in one moderation_state: hidden, and locked. The
# lock has its own column, locked_at, which is what refuses replies; hidden
# has none on a thread, so the state is all there is of it. Hiding wins the
# shared column: locking or unlocking a hidden thread leaves it hidden (each
# used to overwrite the state and so publish it), and showing it again puts
# back whichever of locked and visible locked_at says.
sub lock_thread ( $self, $input ) {
    my $timestamp = $self->clock->now_iso8601;

    return $self->_apply_action(
        {
            %{$input},
            action_type => 'thread.locked',
            applied     => \&_is_locked,
            created_at  => $timestamp,
            lock_kind   => $TARGET_THREAD,
            resultset   => 'Thread',
            target_id   => $input->{thread_id},
            target_type => $TARGET_THREAD,
            updates     => sub ($thread) {
                return {
                    locked_at        => $timestamp,
                    moderation_state =>
                      _unless_hidden( $thread, $STATE_LOCKED ),
                };
            },
        }
    );
}

# A thread is unlocked once neither locked_at nor its state says locked, so
# unlocking such a thread still puts its state right.
sub unlock_thread ( $self, $input ) {
    return $self->_apply_action(
        {
            %{$input},
            action_type => 'thread.unlocked',
            applied     => sub ($thread) {
                return !_is_locked($thread)
                  && _state($thread) ne $STATE_LOCKED ? 1 : 0;
            },
            created_at  => $self->clock->now_iso8601,
            lock_kind   => $TARGET_THREAD,
            resultset   => 'Thread',
            target_id   => $input->{thread_id},
            target_type => $TARGET_THREAD,
            updates     => sub ($thread) {
                return {
                    locked_at        => undef,
                    moderation_state =>
                      _unless_hidden( $thread, $STATE_VISIBLE ),
                };
            },
        }
    );
}

# Threads have no hidden_at, unlike posts: writing one died on PostgreSQL
# ("No such column"), so no thread could be hidden or shown again. When it
# was hidden is the created_at of the action row recorded with it.
sub hide_thread ( $self, $input ) {
    return $self->_apply_action(
        {
            %{$input},
            action_type => 'thread.hidden',
            applied     => \&_is_hidden,
            created_at  => $self->clock->now_iso8601,
            lock_kind   => $TARGET_THREAD,
            resultset   => 'Thread',
            target_id   => $input->{thread_id},
            target_type => $TARGET_THREAD,
            updates     => { moderation_state => $STATE_HIDDEN },
        }
    );
}

sub restore_thread ( $self, $input ) {
    return $self->_apply_action(
        {
            %{$input},
            action_type => 'thread.restored',
            applied     => sub ($thread) {
                return _is_hidden($thread) ? 0 : 1;
            },
            created_at  => $self->clock->now_iso8601,
            lock_kind   => $TARGET_THREAD,
            resultset   => 'Thread',
            target_id   => $input->{thread_id},
            target_type => $TARGET_THREAD,
            updates     => sub ($thread) {
                my $shown =
                  _is_locked($thread) ? $STATE_LOCKED : $STATE_VISIBLE;

                return { moderation_state => $shown };
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

            if ( defined _column( $action, 'reversed_at' ) ) {
                return {
                    moderation_action_id =>
                      _column( $action, 'moderation_action_id' ),
                    reversed_at         => _column( $action, 'reversed_at' ),
                    reversed_by_user_id =>
                      _column( $action, 'reversed_by_user_id' ),
                };
            }

            my $changes = {
                reversed_at         => $timestamp,
                reversed_by_user_id => $reversed_by_user_id,
            };
            $action->update($changes);
            my $correlation_id = $self->id_service->uuid;
            $self->recorder->record_event(
                %{
                    $self->events->reversal_envelope(
                        {
                            action              => $action,
                            action_id           => $action_id,
                            correlation_id      => $correlation_id,
                            reason              => $reason,
                            reversed_by_user_id => $reversed_by_user_id,
                            reversed_at         => $timestamp,
                        }
                    )
                }
            );
            $self->recorder->record_audit(
                %{
                    $self->events->reversal_audit(
                        {
                            action         => $action,
                            correlation_id => $correlation_id,
                            reason         => $reason,
                            reversed_at    => $timestamp,
                            reversed_by    => $reversed_by_user_id,
                        }
                    )
                }
            );

            return { moderation_action_id => $action_id, %{$changes} };
        }
    );
}

# Under a lock on the target, a command already recorded is replayed. A
# target already in the state the action sets answers with the action that
# set it; with none on record, the action is recorded as idempotent and the
# target left as it is.
sub _apply_action ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            my $dbh = GPForum::Infrastructure::Storage->dbh_of( $self->schema );
            if ($dbh) {
                $dbh->selectrow_array( $LOCK_SQL_FOR{ $input->{lock_kind} },
                    undef, $input->{target_id} );
            }
            my $replayed = $self->_find_command_action( $input->{command_id} );
            if ($replayed) {
                return $self->_finish_leftover_action( $replayed, $input );
            }
            my $target =
              $self->schema->resultset( $input->{resultset} )
              ->find( $input->{target_id} );
            if ( !$target ) {
                return undef;
            }

            my $idempotent = $input->{applied}->($target) ? 1 : 0;
            if ($idempotent) {
                my $latest =
                  $self->schema->resultset('ModerationAction')->search_rs(
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
                  );
                my $existing = $latest->single;
                if ($existing) {
                    return {
                        action     => _action_hash($existing),
                        idempotent => 1,
                        ok         => 1,
                        skipped    => 1,
                    };
                }
            }

            my $previous_state = _column( $target, 'moderation_state' );
            if ( !$idempotent ) {
                my $updates = $input->{updates};
                $target->update(
                    ref $updates eq 'CODE' ? $updates->($target) : $updates );
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
    );
}

sub _state ($target) {
    return _column( $target, 'moderation_state' ) || q{};
}

sub _is_hidden ($target) {
    return _state($target) eq $STATE_HIDDEN ? 1 : 0;
}

# locked_at is the lock: it is what refuses a reply and what the page shows,
# and hidden, the state no longer says locked at all. A state saying locked
# without it used to count as locked, so locking that thread was a repeat
# and replies stayed open.
sub _is_locked ($thread) {
    return defined _column( $thread, 'locked_at' ) ? 1 : 0;
}

sub _unless_hidden ( $thread, $state ) {
    return _is_hidden($thread) ? $STATE_HIDDEN : $state;
}

sub _find_command_action ( $self, $command_id ) {
    if ( !defined $command_id || !length $command_id ) {
        return undef;
    }

    return $self->schema->resultset('ModerationAction')
      ->search_rs( { command_id => $command_id }, { rows => 1 }, )
      ->single;
}

# A concurrent request that recorded this command, or a minted id already
# stored under it, is answered by the action the command recorded; a minted
# id with none is minted once more.
sub _record_action ( $self, $input ) {
    my $insert = sub {
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
    };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $insert );
    if ( !$created ) {
        my $conflict = GPForum::X::Conflict->caught($error);
        my $id_taken = $conflict && $conflict->on($ID_CONSTRAINT);
        if ( $id_taken || ( $conflict && $conflict->on($COMMAND_CONSTRAINT) ) )
        {
            my $existing = $self->_find_command_action( $input->{command_id} );
            if ($existing) {
                return $self->_finish_leftover_action( $existing, $input );
            }
        }
        if ( !$id_taken ) {
            GPForum::Infrastructure::UniqueConflict->rethrow($error);
        }
        ( $created, $error ) =
          GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
            $insert );
        if ( !$created ) {
            GPForum::Infrastructure::UniqueConflict->rethrow($error);
        }
    }

    $self->_record_event_and_audit(
        {
            action         => $created,
            correlation_id => $input->{correlation_id},
        }
    );

    return { action => $created, ok => 1 };
}

# An earlier attempt may have committed the action without its event.
sub _finish_leftover_action ( $self, $existing, $input ) {
    my $event_key = join q{:},
      map { _column( $existing, $_ ) }
      qw(action_type target_type target_id moderation_action_id);
    if ( !$self->recorder->event_recorded($event_key) ) {
        $self->_record_event_and_audit(
            {
                action         => $existing,
                correlation_id => $input->{correlation_id},
            }
        );
    }

    return {
        action   => _action_hash($existing),
        ok       => 1,
        replayed => 1,
    };
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
Each action changes the target's C<moderation_state> (and a post's
C<hidden_at> or a thread's C<locked_at>), inserts a C<moderation_actions> row
and records the matching event, its outbox message and the audit entry
through L<GPForum::Infrastructure::EventRecorder>, with shapes from
L<GPForum::Service::Moderation::Event>; all of it in one transaction, after
the target row has been locked with C<SELECT ... FOR UPDATE> so two
moderators acting on the same post or thread take turns.

A thread has no C<hidden_at>: hidden is its C<moderation_state> alone, and
when it was hidden is the action row's C<created_at>. The same column also
says C<locked>, so hidden takes precedence there: locking or unlocking a
hidden thread changes C<locked_at> and leaves it C<hidden>, and showing it
again sets C<locked> or C<visible> by C<locked_at>.

Every action is safe to repeat:

=over 4

=item * A command id that already has an action row is a replay: nothing
changes, the stored action comes back with C<< replayed => 1 >>, and the
action's event and audit are written first if an earlier attempt left the
row without them.

=item * A target where the action is already done is not updated: a post
or thread already hidden, a post already visible, a thread already not
hidden, locked (C<locked_at> set, whatever the state says) or unlocked (no
C<locked_at> and a state other than C<locked>). When an unreversed action
of the same type exists for it, that action comes back with
C<< skipped => 1 >> and C<< idempotent => 1 >>; otherwise a new action is
recorded with C<< idempotent => 1 >> in its metadata.

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
action C<thread.hidden>. Nothing else on the thread changes; a locked
thread keeps its C<locked_at>.

=head2 restore_thread

As L</hide_thread>, setting the state back to C<locked> when C<locked_at>
is set and to C<visible> otherwise, and recording C<thread.restored>. A
thread that is not hidden is left as it is.

=head2 lock_thread

As L</hide_thread>, stamping C<locked_at>, setting the state to C<locked>
unless the thread is hidden, which it stays, and recording
C<thread.locked>.

=head2 unlock_thread

As L</hide_thread>, clearing C<locked_at>, setting the state to C<visible>
unless the thread is hidden, which it stays, and recording
C<thread.unlocked>.

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
L<GPForum::Infrastructure::Storage>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::X::Conflict>,
L<GPForum::Infrastructure::Row>, L<GPForum::Infrastructure::Id>,
L<GPForum::Service::Clock>, L<GPForum::Service::Moderation::Event>.

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
