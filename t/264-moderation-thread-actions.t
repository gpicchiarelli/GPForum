# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Fatal;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Moderation::ActionStore;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;

our $VERSION = '0.001';

const my $NOW       => '2026-05-23T12:00:00Z';
const my $THREAD_ID => 'thread-1';
const my $POST_ID   => 'post-1';
const my %RESULT_CLASS_FOR => map { $_ => "GPForum::Schema::Result::$_" }
  qw(AuditLog EventLog ModerationAction OutboxMessage Post Thread);
const my $NO_COLUMN =>
  qr/No [ ] such [ ] column [ ] 'hidden_at' [ ] on [ ] \S+::Thread/msx;

# ActionStore wrote a hidden_at onto threads, a column only posts have. The
# moderation doubles took any column, so the unit test passed and PostgreSQL
# refused the write: no thread could be hidden or shown again. Here every
# thread and post action runs against doubles bound to the real result
# classes, which refuse a column the table does not have, the way
# DBIx::Class does.

subtest 'the doubles refuse a column the table does not have' => sub {
    my $schema = _schema();

    like(
        exception {
            $schema->resultset('Thread')
              ->create( { hidden_at => undef, thread_id => 'thread-2' } )
        },
        $NO_COLUMN,
        'a thread cannot be created with a hidden_at'
    );
    my $thread = $schema->resultset('Thread')->find($THREAD_ID);
    like( exception { $thread->get_column('hidden_at') },
        $NO_COLUMN, 'nor read one' );
    like( exception { $thread->update( { hidden_at => $NOW } ) },
        $NO_COLUMN, 'nor written one' );
    is(
        exception {
            $schema->resultset('Post')
              ->find($POST_ID)
              ->update( { hidden_at => $NOW } )
        },
        undef,
        'while a post has its hidden_at'
    );
};

subtest 'a thread is hidden and shown again by its state' => sub {
    my $schema = _schema();
    my $store  = _store($schema);

    my $hidden = $store->hide_thread( _command('off-topic') );
    ok( $hidden->{ok}, 'hiding the thread succeeds' );
    is( _thread( $schema, 'moderation_state' ),
        'hidden', 'its state is hidden' );
    is( $hidden->{action}{action_type}, 'thread.hidden',
        'the action is named' );
    _records_one( $schema, 'thread.hidden' );

    my $again = $store->hide_thread( _command('still off-topic') );
    ok( $again->{skipped}, 'hiding it again changes nothing' );
    is(
        $again->{action}{moderation_action_id},
        $hidden->{action}{moderation_action_id},
        'and answers with the first action'
    );
    _records_one( $schema, 'thread.hidden' );

    my $restored = $store->restore_thread( _command('cleared') );
    ok( $restored->{ok}, 'showing it again succeeds' );
    is( _thread( $schema, 'moderation_state' ),
        'visible', 'it is visible again' );
    _records_one( $schema, 'thread.restored' );
};

# The state says hidden or locked, never both. Lock and unlock used to
# overwrite it, and so published a hidden thread; showing a locked thread
# again said visible, after which unlock found nothing to do and the thread
# stayed locked.
subtest 'a hidden thread stays hidden through lock and unlock' => sub {
    my $schema = _schema();
    my $store  = _store($schema);

    $store->lock_thread( _command('heated') );
    is( _thread( $schema, 'moderation_state' ), 'locked', 'locking it' );
    $store->hide_thread( _command('off-topic') );
    is( _thread( $schema, 'moderation_state' ),
        'hidden', 'hiding a locked thread hides it' );
    is( _thread( $schema, 'locked_at' ), $NOW, 'and keeps its lock' );

    $store->unlock_thread( _command('calmer') );
    is( _thread( $schema, 'moderation_state' ),
        'hidden', 'unlocking a hidden thread leaves it hidden' );
    is( _thread( $schema, 'locked_at' ), undef, 'and takes the lock off' );

    my $locked = $store->lock_thread( _command('heated again') );
    is( _thread( $schema, 'moderation_state' ),
        'hidden', 'locking a hidden thread leaves it hidden' );
    is( _thread( $schema, 'locked_at' ), $NOW, 'and puts the lock on' );
    ok( !$locked->{skipped}, 'as a change' );
    ok( $store->lock_thread( _command('heated still') )->{skipped},
        'locking it once more is not one' );

    $store->restore_thread( _command('cleared') );
    is( _thread( $schema, 'moderation_state' ),
        'locked', 'shown again, it is locked' );
    $store->unlock_thread( _command('calm') );
    is( _thread( $schema, 'moderation_state' ),
        'visible', 'and unlocking it then makes it visible' );
    is( _thread( $schema, 'locked_at' ), undef, 'without a lock' );
};

# Showing again is undoing a hide. On a thread that is not hidden it used to
# write visible over locked, which left the lock in locked_at and the state
# saying otherwise; there is nothing to undo, so it is recorded as a repeat.
subtest 'a thread that is not hidden is not shown again' => sub {
    my $visible = _schema();
    my $shown = _store($visible)->restore_thread( _command('nothing hidden') );
    ok(
        $shown->{action}{metadata}{idempotent},
        'showing a visible thread is a repeat'
    );
    is( _thread( $visible, 'moderation_state' ),
        'visible', 'and leaves it visible' );

    my $locked = _schema();
    my $store  = _store($locked);
    $store->lock_thread( _command('heated') );
    $shown = $store->restore_thread( _command('nothing hidden') );
    ok(
        $shown->{action}{metadata}{idempotent},
        'showing a locked thread is a repeat'
    );
    is( $shown->{action}{metadata}{previous_state},
        'locked', 'recorded against its state' );
    is( _thread( $locked, 'moderation_state' ),
        'locked', 'and leaves it locked' );
    is( _thread( $locked, 'locked_at' ), $NOW, 'with its lock' );
    _records_one( $locked, 'thread.restored' );
};

# locked_at is the lock: it refuses a reply and it is what the page shows. A
# state saying locked with no locked_at used to count as locked too, so
# locking that thread recorded a repeat and left replies open.
subtest 'the lock is locked_at, whatever the state says' => sub {
    my $schema = _schema( moderation_state => 'locked' );
    my $locked = _store($schema)->lock_thread( _command('heated') );
    ok(
        !$locked->{action}{metadata}{idempotent},
        'locking a thread with no locked_at is a change'
    );
    is( _thread( $schema, 'locked_at' ), $NOW, 'and puts the lock on' );
    is( _thread( $schema, 'moderation_state' ),
        'locked', 'under the state it had' );

    $schema = _schema( moderation_state => 'locked' );
    my $unlocked = _store($schema)->unlock_thread( _command('calm') );
    ok( !$unlocked->{action}{metadata}{idempotent},
        'unlocking it is a change too' );
    is( _thread( $schema, 'moderation_state' ),
        'visible', 'which leaves a state that no longer says locked' );

    $schema = _schema( locked_at => $NOW );
    ok(
        _store($schema)->lock_thread( _command('heated') )
          ->{action}{metadata}{idempotent},
        'while a thread with a locked_at is locked already'
    );
};

subtest 'a post is hidden and restored with its hidden_at' => sub {
    my $schema = _schema();
    my $store  = _store($schema);

    ok( $store->hide_post( _post_command('spam') )->{ok}, 'hiding a post' );
    is( _post( $schema, 'moderation_state' ), 'hidden', 'sets its state' );
    is( _post( $schema, 'hidden_at' ),        $NOW,     'and its hidden_at' );
    _records_one( $schema, 'post.hidden' );

    ok( $store->restore_post( _post_command('not spam') )->{ok},
        'restoring it' );
    is( _post( $schema, 'moderation_state' ), 'visible', 'sets it visible' );
    is( _post( $schema, 'hidden_at' ), undef, 'and clears its hidden_at' );
    _records_one( $schema, 'post.restored' );
};

done_testing();

# The thread starts visible and unlocked unless %thread says otherwise.
sub _schema {
    my (%thread) = @_;

    my %resultsets =
      map {
        $_ => GPForum::Test::ModerationResultSet->new(
            result_class => $RESULT_CLASS_FOR{$_} )
      } keys %RESULT_CLASS_FOR;
    $resultsets{Thread}->create(
        {
            locked_at        => undef,
            moderation_state => 'visible',
            thread_id        => $THREAD_ID,
            %thread,
        }
    );
    $resultsets{Post}->create(
        {
            hidden_at        => undef,
            moderation_state => 'visible',
            post_id          => $POST_ID,
        }
    );

    return GPForum::Test::ModerationSchema->new( resultsets => \%resultsets );
}

sub _store {
    my ($schema) = @_;

    return GPForum::Service::Moderation::ActionStore->new(
        clock      => GPForum::Test::FixedClock->new( iso8601 => $NOW ),
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
    );
}

sub _command {
    my ($reason) = @_;

    return {
        actor_user_id => 'moderator-1',
        reason        => $reason,
        thread_id     => $THREAD_ID,
    };
}

sub _post_command {
    my ($reason) = @_;

    return {
        actor_user_id => 'moderator-1',
        post_id       => $POST_ID,
        reason        => $reason,
    };
}

sub _thread {
    my ( $schema, $column ) = @_;

    return $schema->resultset('Thread')->find($THREAD_ID)->get_column($column);
}

sub _post {
    my ( $schema, $column ) = @_;

    return $schema->resultset('Post')->find($POST_ID)->get_column($column);
}

# One action row of the type, with its event, the event's outbox message and
# the audit entry.
sub _records_one {
    my ( $schema, $action_type ) = @_;

    my @events = grep { $_->{event_type} eq $action_type }
      @{ $schema->resultset('EventLog')->created };
    my %event_ids = map  { $_->{event_id} => 1 } @events;
    my @audits    = grep { $_->{action} eq $action_type }
      @{ $schema->resultset('AuditLog')->created };
    my @actions = grep { $_->{action_type} eq $action_type }
      @{ $schema->resultset('ModerationAction')->created };
    my @messages = grep { $event_ids{ $_->{event_id} } }
      @{ $schema->resultset('OutboxMessage')->created };

    is( scalar @actions,  1, "$action_type: one action row" );
    is( scalar @events,   1, "$action_type: one event" );
    is( scalar @messages, 1, "$action_type: one outbox message for it" );
    is( scalar @audits,   1, "$action_type: one audit entry" );

    return;
}

1;
