# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::AdminBootstrap;
use GPForum::Infrastructure::Id;
use GPForum::Service::Moderation::ActionStore;
use GPForum::Service::Password;
use GPForum::Test::PgDatabase;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $HTTP_OK        => 200;
const my $HTTP_NOT_FOUND => 404;
const my $PASSWORD       => 'correct horse battery staple';
const my $MODERATOR      => 'thread_moderator';
const my $JSON           => { Accept => 'application/json' };
const my $THREAD_COUNT   => 4;
const my $REVERSED       => 'moderation_action.reversed';

# Threads and posts no moderator has touched, so an action's rows are the
# only ones of their kind for the target.
const my $THREADS_SQL => join q{ },
  'SELECT t.thread_id FROM threads t',
  q{WHERE t.deleted_at IS NULL AND t.visibility = 'public'},
  q{AND t.moderation_state = 'visible' AND t.locked_at IS NULL},
  'AND NOT EXISTS (SELECT 1 FROM moderation_actions m',
  'WHERE m.target_id = t.thread_id)',
  'ORDER BY t.thread_id LIMIT ?';
const my $POST_SQL => join q{ },
  'SELECT p.post_id FROM posts p',
  q{WHERE p.deleted_at IS NULL AND p.moderation_state = 'visible'},
  'AND p.hidden_at IS NULL',
  'AND NOT EXISTS (SELECT 1 FROM moderation_actions m',
  'WHERE m.target_id = p.post_id)',
  'ORDER BY p.post_id LIMIT 1';
const my $THREAD_SQL =>
  'SELECT moderation_state, locked_at IS NOT NULL FROM threads'
  . ' WHERE thread_id = ?';
const my $POST_STATE_SQL =>
  'SELECT moderation_state, hidden_at IS NOT NULL FROM posts WHERE post_id = ?';
const my $ACTIONS_SQL => 'SELECT count(*) FROM moderation_actions'
  . ' WHERE action_type = ? AND target_id = ?';
const my $REPEATS_SQL => $ACTIONS_SQL
  . q{ AND (metadata ->> 'idempotent')::integer = 1};
const my $EVENTS_SQL =>
  'SELECT count(*) FROM event_log WHERE event_type = ? AND aggregate_id = ?';
const my $OUTBOX_SQL => join q{ },
  'SELECT count(*) FROM outbox_messages o',
  'JOIN event_log e ON e.event_id = o.event_id',
  'WHERE e.event_type = ? AND e.aggregate_id = ?';
const my $AUDITS_SQL =>
  'SELECT count(*) FROM audit_log WHERE action = ? AND target_id = ?';
const my $STATE_ONLY_LOCK_SQL =>
  q{UPDATE threads SET moderation_state = 'locked'} . ' WHERE thread_id = ?';
const my $REVERSED_SQL => 'SELECT reversed_by_user_id FROM moderation_actions'
  . ' WHERE moderation_action_id = ? AND reversed_at IS NOT NULL';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all =>
      'set GPFORUM_DATABASE_DSN to run the thread moderation test';
}

# ActionStore stamped hidden_at on a thread, a column only posts have, and
# PostgreSQL refused it: the hide-thread route answered 503 and no thread
# could be hidden or shown again. Every ActionStore write to a thread or a
# post runs here against the migrated schema, so no other column the tables
# lack can hide behind a double.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;

my $database = GPForum::Test::PgDatabase->fresh( seed => 1 );
local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;
my $dbh = $database->dbh;

my $moderator_id = _moderator();
my @threads =
  @{ $dbh->selectcol_arrayref( $THREADS_SQL, undef, $THREAD_COUNT ) };
my ($post_id) = $dbh->selectrow_array($POST_SQL);
is( scalar @threads, $THREAD_COUNT, 'the seed provides untouched threads' );
ok( $post_id, 'and an untouched post' );

my $store =
  GPForum::Service::Moderation::ActionStore->new( schema => $database->schema );

my ( $routed, $shown, $through_lock, $state_only ) = @threads;
_route_hides_and_shows($routed);
_thread_hidden_and_shown($shown);
_hidden_thread_through_lock($through_lock);
_lock_is_locked_at($state_only);
_post_hidden_and_restored($post_id);

done_testing();

sub _thread_hidden_and_shown {
    my ($thread_id) = @_;

    my $command = _command( thread_id => $thread_id );
    my $hidden  = $store->hide_thread($command);
    ok( $hidden->{ok}, 'a moderator hides a thread' );
    is_deeply( _thread($thread_id), [ 'hidden', 0 ], 'its state is hidden' );
    _records_one( 'thread.hidden', $thread_id );

    ok(
        $store->hide_thread($command)->{replayed},
        'the same command again is a replay'
    );
    ok( $store->hide_thread( _command( thread_id => $thread_id ) )->{skipped},
        'hiding it again changes nothing' );
    _records_one( 'thread.hidden', $thread_id );

    ok( $store->restore_thread( _command( thread_id => $thread_id ) )->{ok},
        'and shows it again' );
    is_deeply( _thread($thread_id), [ 'visible', 0 ], 'it is visible' );
    _records_one( 'thread.restored', $thread_id );

    return;
}

# Locked and hidden share the state column; locked_at alone carries the
# lock while the thread is hidden, and showing a thread that is not hidden
# has no hide to undo.
sub _hidden_thread_through_lock {
    my ($thread_id) = @_;

    my @steps = (
        [ lock_thread    => [ 'locked',  1 ], 'locking it' ],
        [ restore_thread => [ 'locked',  1 ], 'showing it changes nothing' ],
        [ hide_thread    => [ 'hidden',  1 ], 'hiding it keeps the lock' ],
        [ unlock_thread  => [ 'hidden',  0 ], 'unlocking it keeps it hidden' ],
        [ lock_thread    => [ 'hidden',  1 ], 'locking it keeps it hidden' ],
        [ restore_thread => [ 'locked',  1 ], 'shown again, it is locked' ],
        [ unlock_thread  => [ 'visible', 0 ], 'unlocked, it is visible' ],
    );
    for my $step (@steps) {
        my ( $action, $expected, $name ) = @{$step};
        ok( $store->$action( _command( thread_id => $thread_id ) )->{ok},
            "$action succeeds" );
        is_deeply( _thread($thread_id), $expected, $name );
    }
    is( _count( $ACTIONS_SQL, 'thread.locked', $thread_id ),
        2, 'each lock is recorded' );
    is( _count( $EVENTS_SQL, 'thread.unlocked', $thread_id ),
        2, 'and each unlock has its event' );
    is( _count( $REPEATS_SQL, 'thread.restored', $thread_id ),
        1, 'showing the thread while it was not hidden is a recorded repeat' );

    return;
}

# A state saying locked with no locked_at is not locked: replies go by
# locked_at. Locking it used to record a repeat and leave replies open.
sub _lock_is_locked_at {
    my ($thread_id) = @_;

    $dbh->do( $STATE_ONLY_LOCK_SQL, undef, $thread_id );
    my $locked = $store->lock_thread( _command( thread_id => $thread_id ) );
    ok( !$locked->{action}{metadata}{idempotent},
        'locking a thread whose state alone says locked is a change' );
    is_deeply( _thread($thread_id), [ 'locked', 1 ], 'that sets locked_at' );

    return;
}

sub _post_hidden_and_restored {
    my ($post) = @_;

    my $hidden = $store->hide_post( _command( post_id => $post ) );
    ok( $hidden->{ok}, 'a moderator hides a post' );
    is_deeply( _post($post), [ 'hidden', 1 ], 'with its hidden_at' );
    _records_one( 'post.hidden', $post );

    ok( $store->restore_post( _command( post_id => $post ) )->{ok},
        'and restores it' );
    is_deeply( _post($post), [ 'visible', 0 ], 'clearing its hidden_at' );
    _records_one( 'post.restored', $post );

    my $action_id = $hidden->{action}{moderation_action_id};
    my $reversed =
      $store->reverse_action( $action_id, $moderator_id, 'appeal upheld' );
    is( $reversed->{moderation_action_id},
        $action_id, 'the hide can be reversed' );
    is( scalar $dbh->selectrow_array( $REVERSED_SQL, undef, $action_id ),
        $moderator_id, 'the action row names who reversed it' );
    is( _count( $EVENTS_SQL, $REVERSED, $action_id ),
        1, 'the reversal has its event' );
    is( _count( $OUTBOX_SQL, $REVERSED, $action_id ),
        1, 'and its outbox message' );
    is( _count( $AUDITS_SQL, $REVERSED, $post ),
        1, 'and an audit entry on the post' );

    return;
}

# The moderator's route, which answered 503 while the store died.
sub _route_hides_and_shows {
    my ($thread_id) = @_;

    my $client    = _signed_in();
    my $anonymous = Test::Mojo->new( $client->app );

    _post_action( $client, "/moderation/threads/$thread_id/hide" );
    $client->status_is($HTTP_OK)
      ->json_is( '/action/action_type' => 'thread.hidden' );
    is_deeply(
        _thread($thread_id),
        [ 'hidden', 0 ],
        'the route hides the thread'
    );
    $anonymous->get_ok("/t/$thread_id")->status_is($HTTP_NOT_FOUND);

    _post_action( $client, "/moderation/threads/$thread_id/restore" );
    $client->status_is($HTTP_OK)
      ->json_is( '/action/action_type' => 'thread.restored' );
    is_deeply( _thread($thread_id), [ 'visible', 0 ], 'and shows it again' );
    $anonymous->get_ok("/t/$thread_id")->status_is($HTTP_OK);

    return;
}

sub _post_action {
    my ( $client, $path ) = @_;

    $client->get_ok('/moderation/reports')->status_is($HTTP_OK);
    my $page = $client->tx->res->dom;
    my $csrf = $page->at('input[name=csrf_token]');
    $client->post_ok(
        $path => $JSON => form => {
            command_id => GPForum::Infrastructure::Id->new->uuid,
            csrf_token => $csrf ? $csrf->attr('value') : q{},
            reason     => 'integration thread moderation',
        }
    );

    return;
}

sub _signed_in {
    my $client = Test::Mojo->new('GPForum');
    $client->get_ok('/login');
    my $form = $client->tx->res->dom;
    $client->post_ok(
        '/login' => form => {
            command_id => $form->at('input[name=command_id]')->attr('value'),
            csrf_token => $form->at('input[name=csrf_token]')->attr('value'),
            identifier => $MODERATOR,
            password   => $PASSWORD,
        }
    );
    $client->get_ok('/settings')
      ->status_is( $HTTP_OK, 'the moderator signs in' );

    return $client;
}

# A user with a password, given the bootstrap moderation role.
sub _moderator {
    my $hash = GPForum::Service::Password->new->hash_password($PASSWORD);
    my ($id) = $dbh->selectrow_array(
        q{INSERT INTO users (id, username, display_name, email_normalized,}
          . q{ password_hash, status) VALUES (gen_random_uuid(), ?,}
          . q{ 'Thread moderator', 'thread-moderator@example.test', ?,}
          . q{ 'active') RETURNING id},
        undef, $MODERATOR, $hash
    );
    $dbh->do(
        q{INSERT INTO credentials (id, user_id, type, secret_hash)}
          . q{ VALUES (gen_random_uuid(), ?, 'password', ?)},
        undef, $id, $hash
    );
    is(
        GPForum::Test::PostgresHarness::quietly(
            sub {
                return GPForum::Command::AdminBootstrap->new->run( '--user-id',
                    $id );
            }
        ),
        0,
        'the moderator receives the bootstrap moderation role'
    );

    return $id;
}

sub _command {
    my (%target) = @_;

    return {
        actor_user_id => $moderator_id,
        command_id    => GPForum::Infrastructure::Id->new->uuid,
        reason        => 'integration thread moderation',
        %target,
    };
}

sub _thread {
    my ($thread_id) = @_;

    return [ $dbh->selectrow_array( $THREAD_SQL, undef, $thread_id ) ];
}

sub _post {
    my ($post) = @_;

    return [ $dbh->selectrow_array( $POST_STATE_SQL, undef, $post ) ];
}

sub _count {
    my ( $sql, @bind ) = @_;

    return scalar $dbh->selectrow_array( $sql, undef, @bind );
}

# One action row, its event, the event's outbox message and the audit entry.
sub _records_one {
    my ( $type, $target_id ) = @_;

    is( _count( $ACTIONS_SQL, $type, $target_id ), 1, "$type: one action row" );
    is( _count( $EVENTS_SQL,  $type, $target_id ), 1, "$type: one event" );
    is( _count( $OUTBOX_SQL,  $type, $target_id ),
        1, "$type: one outbox message" );
    is( _count( $AUDITS_SQL, $type, $target_id ), 1, "$type: one audit entry" );

    return;
}

1;
