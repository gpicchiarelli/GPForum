# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::Id;
use GPForum::Infrastructure::Row;
use GPForum::Service::Admin::AuditReview;
use GPForum::Service::Moderation::ActionStore;
use GPForum::Service::Moderation::ReportStore;
use GPForum::Service::Moderation::ReviewReader;
use GPForum::Service::Moderation::SuspensionStore;
use GPForum::Test::FixedClock;
use GPForum::Test::PgDatabase;
use GPForum::Test::ScriptedId;

our $VERSION = '0.001';
our $TODO;

const my $NOW          => '2026-05-23T12:00:00Z';
const my $AN_HOUR_ON   => '2026-05-23T13:00:00Z';
const my $LATER        => '2026-05-23T12:05:00Z';
const my $TONIGHT      => '2026-05-23T18:00:00Z';
const my $TOMORROW     => '2026-05-24T12:00:00Z';
const my $HALF_PAST    => '2026-05-23T11:30:00Z';
const my $BEFORE       => '2026-05-23T11:00:00Z';
const my $TEN          => '2026-05-23T10:00:00Z';
const my $NINE_THIRTY  => '2026-05-23T09:30:00Z';
const my $NINE         => '2026-05-23T09:00:00Z';
const my $EIGHT        => '2026-05-23T08:00:00Z';
const my $YESTERDAY    => '2026-05-22T10:00:00Z';
const my $YESTERDAY_TO => '2026-05-22T12:00:00Z';

const my $QUEUE_LIMIT    => 25;
const my $AUDIT_LIMIT    => 3;
const my $HISTORY_LIMIT  => 10;
const my $MAX_PAGES      => 100;
const my $REPORT_EVENTS  => 4;
const my $TARGET_ACTIONS => 4;
const my $REVOKE_EVENTS  => 2;
const my $TIED_STARTS    => 3;

# Fixed ids, so the history's ties on created_at are broken in a known order.
const my $NEWEST     => '018f1000-0000-7000-8000-00000000a00a';
const my $TIED_HIGH  => '018f1000-0000-7000-8000-00000000a00c';
const my $TIED_LOW   => '018f1000-0000-7000-8000-00000000a00b';
const my $OTHER      => '018f1000-0000-7000-8000-00000000a00d';
const my $OLDEST     => '018f1000-0000-7000-8000-00000000a001';
const my $NOT_CURSOR => 'bm90IGEgY3Vyc29y';

const my $USER_SQL => join q{ },
  'INSERT INTO users (id, username, display_name, email_normalized,',
  q{password_hash, status, updated_at) VALUES (?, ?, ?, ?, 'x', ?, ?)};
const my $SPACE_SQL => join q{ },
  'INSERT INTO spaces (space_id, slug, title)',
  q{VALUES (?, 'moderation', 'Moderation')};
const my $CATEGORY_SQL => join q{ },
  'INSERT INTO categories (category_id, space_id, slug, title)',
  q{VALUES (?, ?, 'review', 'Review')};
const my $THREAD_SQL => join q{ },
  'INSERT INTO threads (thread_id, category_id, author_user_id, title, slug)',
  q{VALUES (?, ?, ?, 'Under review', 'under-review')};
const my $POST_SQL => join q{ },
  'INSERT INTO posts (post_id, thread_id, author_user_id, position)',
  'VALUES (?, ?, ?, 1)';
const my $ACTION_SQL => join q{ },
  'INSERT INTO moderation_actions (moderation_action_id, action_type,',
  'target_type, target_id, created_at, actor_user_id, reason)',
  q{VALUES (?, ?, ?, ?, ?, ?, 'history')};
const my $SUSPENSION_SQL => join q{ },
  'INSERT INTO suspensions (suspension_id, user_id, actor_user_id, reason,',
  q{valid_from, valid_to, revoked_at) VALUES (?, ?, ?, 'review', ?, ?, ?)};
const my $SUSPEND_AGAIN_SQL =>
  q{UPDATE users SET status = 'suspended', updated_at = ? WHERE id = ?};

# A timestamp as the clock writes it, whatever zone the server returns it in.
const my $UTC_SQL => join q{ },
  q{SELECT to_char(?::timestamptz AT TIME ZONE 'UTC',},
  q{'YYYY-MM-DD"T"HH24:MI:SS"Z"')};
const my $REPORT_ROW_SQL => 'SELECT * FROM reports WHERE report_id = ?';
const my $POST_ROW_SQL   => 'SELECT * FROM posts WHERE post_id = ?';
const my $THREAD_ROW_SQL => 'SELECT * FROM threads WHERE thread_id = ?';
const my $USER_ROW_SQL   => 'SELECT * FROM users WHERE id = ?';
const my $SUSPENSION_ROW_SQL =>
  'SELECT * FROM suspensions WHERE suspension_id = ?';
const my $ACTION_ROW_SQL =>
  'SELECT * FROM moderation_actions WHERE moderation_action_id = ?';
const my $REPORTS_SQL => join q{ },
  'SELECT count(*) FROM reports',
  'WHERE reporter_user_id = ? AND target_id = ?';
const my $USER_SUSPENSIONS_SQL =>
  'SELECT count(*) FROM suspensions WHERE user_id = ?';
const my $TARGET_ACTIONS_SQL => join q{ },
  'SELECT count(*) FROM moderation_actions',
  'WHERE action_type = ? AND target_id = ?';
const my $COMMAND_ACTIONS_SQL =>
  'SELECT count(*) FROM moderation_actions WHERE command_id = ?';
const my $ALL_ACTIONS_SQL => join q{ },
  'SELECT moderation_action_id FROM moderation_actions',
  'ORDER BY created_at DESC, moderation_action_id DESC';
const my $EVENTS_SQL =>
  'SELECT count(*) FROM event_log WHERE event_type = ? AND aggregate_id = ?';
const my $AGGREGATE_EVENTS_SQL =>
  'SELECT count(*) FROM event_log WHERE aggregate_id = ?';
const my $AGGREGATE_OUTBOX_SQL => join q{ },
  'SELECT count(*) FROM outbox_messages',
  'JOIN event_log USING (event_id) WHERE event_log.aggregate_id = ?';
const my $KEYED_EVENTS_SQL =>
  'SELECT count(*) FROM event_log WHERE idempotency_key = ?';
const my $KEYED_OUTBOX_SQL => join q{ },
  'SELECT count(*) FROM outbox_messages',
  'JOIN event_log USING (event_id) WHERE event_log.idempotency_key = ?';
const my $AUDITS_SQL =>
  'SELECT count(*) FROM audit_log WHERE action = ? AND target_id = ?';
const my $AUDIT_REASON_SQL => join q{ },
  q{SELECT metadata->>'reason' FROM audit_log},
  'WHERE action = ? AND target_id = ?';
const my $REPORT_AUDITS_SQL => join q{ },
  'SELECT count(*) FROM audit_log',
  q{WHERE action = ? AND metadata->>'report_id' = ?};
const my $DUPLICATE_AUDITS_SQL => join q{ },
  q{SELECT count(*) FROM audit_log WHERE action = 'report.duplicate_blocked'},
  q{AND metadata->>'existing_report_id' = ?};
const my $ACTION_AUDITS_SQL => join q{ },
  'SELECT count(*) FROM audit_log',
  q{WHERE action = ? AND metadata->>'moderation_action_id' = ?};
const my $ACTION_AUDIT_REASON_SQL => join q{ },
  q{SELECT metadata->>'reason' FROM audit_log},
  q{WHERE action = ? AND metadata->>'moderation_action_id' = ?};
const my $AUDIT_COUNT_SQL => 'SELECT count(*) FROM audit_log';
const my @TOTAL_SQLS => map { "SELECT count(*) FROM $_" }
  qw(suspensions event_log outbox_messages audit_log);
const my $TARGET_AUDITS_SQL => join q{ },
  'SELECT audit_id FROM audit_log WHERE target_type = ? AND target_id = ?',
  'ORDER BY created_at DESC, audit_id DESC';
const my $USER_SUSPENSION_IDS_SQL => join q{ },
  'SELECT suspension_id FROM suspensions WHERE user_id = ?',
  'ORDER BY valid_from DESC, suspension_id DESC';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# Moderation review on PostgreSQL: the report queue and its transitions,
# moderation actions and their reversal, suspensions, and the keyset pages
# of the review lists, each with the event, outbox message and audit entry
# it has to leave. These ran on a fake ORM in t/25, which let ActionStore
# write a hidden_at no thread has, and stored timestamps as the strings it
# was given rather than the ones PostgreSQL returns.
my $clone      = GPForum::Test::PgDatabase->fresh;
my $moderation = _context($clone);

_report_lifecycle($moderation);
_post_actions($moderation);
_thread_actions($moderation);
_reversal($moderation);
_command_replay($moderation);
_audit_review($moderation);
_suspension_lifecycle($moderation);
_suspension_id_collision($moderation);
_participation($moderation);
_action_history($moderation);
_suspension_history($moderation);
_suspension_ties($moderation);

done_testing();

sub _context {
    my ($database) = @_;

    my $ctx = {
        clock  => GPForum::Test::FixedClock->new,
        dbh    => $database->dbh,
        ids    => GPForum::Infrastructure::Id->new,
        schema => $database->schema,
    };
    $ctx->{users} = { map { $_ => _user( $ctx, $_ ) }
          qw(reporter moderator reviewer member) };
    _forum($ctx);

    return $ctx;
}

sub _user {
    my ( $ctx, $name, $status ) = @_;

    my $id = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $USER_SQL, undef, $id, $name, ucfirst $name,
        "$name\@example.test", $status // 'active', $BEFORE );

    return $id;
}

# One thread with one post, written by the member who is later suspended.
sub _forum {
    my ($ctx) = @_;

    my $dbh      = $ctx->{dbh};
    my $author   = $ctx->{users}{member};
    my $space    = $ctx->{ids}->uuid;
    my $category = $ctx->{ids}->uuid;
    $ctx->{thread_id} = $ctx->{ids}->uuid;
    $ctx->{post_id}   = $ctx->{ids}->uuid;
    $dbh->do( $SPACE_SQL,    undef, $space );
    $dbh->do( $CATEGORY_SQL, undef, $category,         $space );
    $dbh->do( $THREAD_SQL,   undef, $ctx->{thread_id}, $category,   $author );
    $dbh->do( $POST_SQL, undef, $ctx->{post_id}, $ctx->{thread_id}, $author );

    return;
}

sub _report_lifecycle {
    my ($ctx) = @_;

    my $store  = _store( $ctx, 'GPForum::Service::Moderation::ReportStore' );
    my $report = $store->create_report(
        {
            details          => 'link ripetuti',
            reason           => 'spam',
            reporter_user_id => $ctx->{users}{reporter},
            target_id        => $ctx->{post_id},
            target_type      => 'post',
        }
    );
    my $report_id = $report->{report_id};
    ok( GPForum::Infrastructure::Id->is_uuid($report_id),
        'report id is generated' );
    is(
        $report->{reporter_user_id},
        $ctx->{users}{reporter},
        'report stores reporter'
    );
    is( $report->{target_type}, 'post',          'report stores target type' );
    is( $report->{target_id},   $ctx->{post_id}, 'report stores target id' );
    is( $report->{reason},      'spam',          'report stores reason' );
    is( $report->{status},      'open',          'report starts open' );
    is( $report->{created_at},  $NOW, 'report stores creation time' );

    my $row = _row( $ctx, $REPORT_ROW_SQL, $report_id );
    is( $row->{status}, 'open', 'report row is inserted' );
    is( _utc( $ctx, $row->{created_at} ),
        $NOW, 'report row keeps the creation time' );
    is( _value( $ctx, $EVENTS_SQL, 'report.created', $report_id ),
        1, 'report creation records a domain event' );
    is( _value( $ctx, $AGGREGATE_OUTBOX_SQL, $report_id ),
        1, 'report creation records outbox handoff' );
    is( _value( $ctx, $REPORT_AUDITS_SQL, 'report.created', $report_id ),
        1, 'report creation records audit row with the report id' );

    _duplicate_report( $ctx, $store, $report_id );
    _report_assignment( $ctx, $store, $report_id );
    _report_queue( $ctx, $store, $report_id );
    _report_release( $ctx, $store, $report_id );
    _report_resolution( $ctx, $store, $report_id );

    return;
}

# The open report's unique index is the store-level guard: a second report
# from the same reporter on the same target answers with the first.
sub _duplicate_report {
    my ( $ctx, $store, $report_id ) = @_;

    my $again = $store->create_report(
        {
            reason           => 'spam',
            reporter_user_id => $ctx->{users}{reporter},
            target_id        => $ctx->{post_id},
            target_type      => 'post',
        }
    );
    is( GPForum::Infrastructure::Row->column( $again, 'report_id' ),
        $report_id, 'a duplicate open report answers with the first' );
    is(
        _value( $ctx, $REPORTS_SQL, $ctx->{users}{reporter}, $ctx->{post_id} ),
        1,
        'and inserts no second row'
    );
    is( _value( $ctx, $AGGREGATE_EVENTS_SQL, $report_id ),
        1, 'and emits no second event' );
    is( _value( $ctx, $DUPLICATE_AUDITS_SQL, $report_id ),
        1, 'the duplicate is audited against the first report' );

    return;
}

sub _report_assignment {
    my ( $ctx, $store, $report_id ) = @_;

    my $moderator = $ctx->{users}{moderator};
    my $assigned  = $store->assign_report( $report_id, $moderator );
    is( $assigned->{report_id}, $report_id, 'assignment returns report id' );
    is( $assigned->{assigned_moderator_user_id},
        $moderator, 'assignment stores moderator' );
    is(
        _row( $ctx, $REPORT_ROW_SQL, $report_id )->{assigned_moderator_user_id},
        $moderator,
        'report row receives assigned moderator'
    );
    is( _value( $ctx, $EVENTS_SQL, 'report.assigned', $report_id ),
        1, 'report assignment records a domain event' );
    is( _value( $ctx, $REPORT_AUDITS_SQL, 'report.assigned', $report_id ),
        1, 'assignment records audit row' );

    my $same = $store->assign_report( $report_id, $moderator );
    is( $same->{assigned_moderator_user_id},
        $moderator, 'same assignment is idempotent' );
    is( _value( $ctx, $AGGREGATE_EVENTS_SQL, $report_id ),
        2, 'same assignment does not emit duplicate event' );
    is( _value( $ctx, $REPORT_AUDITS_SQL, 'report.assigned', $report_id ),
        1, 'same assignment writes no second audit row' );

    return;
}

sub _report_queue {
    my ( $ctx, $store, $report_id ) = @_;

    $ctx->{clock}->iso8601($LATER);
    my $later = $store->create_report(
        {
            reason           => 'off-topic',
            reporter_user_id => $ctx->{users}{reviewer},
            target_id        => $ctx->{thread_id},
            target_type      => 'thread',
        }
    );
    my $closed = $store->create_report(
        {
            reason           => 'spam',
            reporter_user_id => $ctx->{users}{member},
            target_id        => $ctx->{post_id},
            target_type      => 'post',
        }
    );
    $store->resolve_report( $closed->{report_id}, 'dismissed',
        $ctx->{users}{moderator} );
    $ctx->{clock}->iso8601($NOW);

    is_deeply(
        _ids( $store->list_queue( { limit => $QUEUE_LIMIT } ), 'report_id' ),
        [ $report_id, $later->{report_id} ],
        'queue lists the open reports, oldest first'
    );
    is_deeply( _ids( $store->list_queue( { limit => 1 } ), 'report_id' ),
        [$report_id], 'queue applies limit' );
    is_deeply(
        _ids(
            $store->list_queue(
                { limit => $QUEUE_LIMIT, status => 'resolved' }
            ),
            'report_id'
        ),
        [ $closed->{report_id} ],
        'queue lists another status when asked'
    );

    return;
}

sub _report_release {
    my ( $ctx, $store, $report_id ) = @_;

    my $moderator = $ctx->{users}{moderator};
    my $released  = $store->release_report( $report_id, $moderator );
    is( $released->{report_id}, $report_id, 'release returns report id' );
    is( $released->{assigned_moderator_user_id},
        undef, 'release clears moderator assignment' );
    is(
        _row( $ctx, $REPORT_ROW_SQL, $report_id )->{assigned_moderator_user_id},
        undef,
        'report row clears assigned moderator'
    );
    is( _value( $ctx, $EVENTS_SQL, 'report.released', $report_id ),
        1, 'release records a domain event' );
    is( _value( $ctx, $REPORT_AUDITS_SQL, 'report.released', $report_id ),
        1, 'release records audit row' );

    my $events = _value( $ctx, $AGGREGATE_EVENTS_SQL, $report_id );
    my $same   = $store->release_report( $report_id, $moderator );
    is( $same->{assigned_moderator_user_id},
        undef, 'same release is idempotent' );
    is( _value( $ctx, $AGGREGATE_EVENTS_SQL, $report_id ),
        $events, 'same release does not emit duplicate event' );
    is( _value( $ctx, $REPORT_AUDITS_SQL, 'report.released', $report_id ),
        1, 'same release writes no second audit row' );

    return;
}

sub _report_resolution {
    my ( $ctx, $store, $report_id ) = @_;

    my $resolved = $store->resolve_report( $report_id, 'hidden_post',
        $ctx->{users}{moderator} );
    is( $resolved->{status},     'resolved',    'report can be resolved' );
    is( $resolved->{resolution}, 'hidden_post', 'resolution reason is stored' );
    is( $resolved->{resolved_at}, $NOW,         'resolution stores timestamp' );

    my $row = _row( $ctx, $REPORT_ROW_SQL, $report_id );
    is( $row->{status}, 'resolved', 'report row is updated as resolved' );
    is( _utc( $ctx, $row->{resolved_at} ),
        $NOW, 'report row keeps the resolution time' );
    is( _value( $ctx, $AGGREGATE_EVENTS_SQL, $report_id ),
        $REPORT_EVENTS, 'report resolution records a domain event' );
    is( _value( $ctx, $AGGREGATE_OUTBOX_SQL, $report_id ),
        $REPORT_EVENTS, 'report transitions record outbox handoffs' );
    is( _value( $ctx, $REPORT_AUDITS_SQL, 'report.resolved', $report_id ),
        1, 'resolution records audit row' );

    my $same = $store->resolve_report( $report_id, 'dismissed',
        $ctx->{users}{moderator} );
    is( $same->{resolution}, 'hidden_post',
        'same resolution is idempotent and keeps the first resolution' );
    is( _value( $ctx, $AGGREGATE_EVENTS_SQL, $report_id ),
        $REPORT_EVENTS, 'same resolution does not emit duplicate event' );
    is( _value( $ctx, $AGGREGATE_OUTBOX_SQL, $report_id ),
        $REPORT_EVENTS, 'nor a second outbox handoff' );
    is( _value( $ctx, $REPORT_AUDITS_SQL, 'report.resolved', $report_id ),
        1, 'nor a second audit row' );

    return;
}

sub _post_actions {
    my ($ctx) = @_;

    my $store = _store( $ctx, 'GPForum::Service::Moderation::ActionStore' );
    my %post  = (
        actor_user_id => $ctx->{users}{moderator},
        post_id       => $ctx->{post_id},
    );
    my $hidden = $store->hide_post( { %post, reason => 'spam' } );
    ok( $hidden->{ok}, 'post hide action succeeds' );
    my $hide = $hidden->{action};
    ok( GPForum::Infrastructure::Id->is_uuid( $hide->{moderation_action_id} ),
        'hide action id is generated' );
    is( $hide->{action_type}, 'post.hidden',   'hide action type stored' );
    is( $hide->{target_type}, 'post',          'hide target type stored' );
    is( $hide->{target_id},   $ctx->{post_id}, 'hide target id stored' );
    my $row = _row( $ctx, $POST_ROW_SQL, $ctx->{post_id} );
    is( $row->{moderation_state}, 'hidden', 'post is hidden' );
    is( _utc( $ctx, $row->{hidden_at} ),
        $NOW, 'post hidden timestamp is stored' );
    _assert_action_recorded( $ctx, $hide, 'spam' );

    my $restored =
      $store->restore_post( { %post, reason => 'appeal accepted' } );
    ok( $restored->{ok}, 'post restore action succeeds' );
    is( $restored->{action}{action_type},
        'post.restored', 'restore action type stored' );
    $row = _row( $ctx, $POST_ROW_SQL, $ctx->{post_id} );
    is( $row->{moderation_state}, 'visible', 'post is restored' );
    is( $row->{hidden_at},        undef, 'post hidden timestamp is cleared' );
    _assert_action_recorded( $ctx, $restored->{action}, 'appeal accepted' );

    $ctx->{hide_action_id} = $hide->{moderation_action_id};

    return;
}

# A thread has no hidden_at: hidden is its moderation_state alone, which
# also says locked, so the lock is kept in locked_at and comes back when the
# thread is shown again.
sub _thread_actions {
    my ($ctx) = @_;

    my $store  = _store( $ctx, 'GPForum::Service::Moderation::ActionStore' );
    my %thread = (
        actor_user_id => $ctx->{users}{moderator},
        thread_id     => $ctx->{thread_id},
    );
    my $locked = $store->lock_thread( { %thread, reason => 'heated' } );
    ok( $locked->{ok}, 'thread lock action succeeds' );
    is( $locked->{action}{action_type},
        'thread.locked', 'lock action type stored' );
    my $row = _row( $ctx, $THREAD_ROW_SQL, $ctx->{thread_id} );
    is( $row->{moderation_state}, 'locked', 'thread is locked' );
    is( _utc( $ctx, $row->{locked_at} ),
        $NOW, 'thread locked timestamp is stored' );
    _assert_action_recorded( $ctx, $locked->{action}, 'heated' );

    my $same = $store->lock_thread( { %thread, reason => 'heated' } );
    ok( $same->{ok},      'same thread lock action succeeds' );
    ok( $same->{skipped}, 'same thread lock is skipped when already locked' );
    ok( $same->{idempotent}, 'same thread lock action is marked idempotent' );
    is(
        $same->{action}{moderation_action_id},
        $locked->{action}{moderation_action_id},
        'same thread lock returns the original action'
    );
    is(
        _value( $ctx, $TARGET_ACTIONS_SQL, 'thread.locked', $ctx->{thread_id} ),
        1,
        'same thread lock records no second action'
    );
    is( _value( $ctx, $EVENTS_SQL, 'thread.locked', $ctx->{thread_id} ),
        1, 'nor a second lock event for the thread, under any key' );
    _assert_recorded_once( $ctx, $locked->{action}, 'after a repeated lock' );

    my $hidden = $store->hide_thread( { %thread, reason => 'off-topic' } );
    ok( $hidden->{ok}, 'thread hide action succeeds' );
    is( $hidden->{action}{action_type},
        'thread.hidden', 'hide thread action type stored' );
    $row = _row( $ctx, $THREAD_ROW_SQL, $ctx->{thread_id} );
    is( $row->{moderation_state}, 'hidden', 'thread is hidden' );
    is( _utc( $ctx, $row->{locked_at} ),
        $NOW, 'thread hide keeps the lock timestamp' );
    _assert_action_recorded( $ctx, $hidden->{action}, 'off-topic' );

    _thread_shown_again( $ctx, $store, \%thread );

    return;
}

sub _thread_shown_again {
    my ( $ctx, $store, $thread ) = @_;

    my $restored =
      $store->restore_thread( { %{$thread}, reason => 'cleared' } );
    ok( $restored->{ok}, 'thread restore action succeeds' );
    is( $restored->{action}{action_type},
        'thread.restored', 'restore thread action type stored' );
    my $row = _row( $ctx, $THREAD_ROW_SQL, $ctx->{thread_id} );
    is( $row->{moderation_state},
        'locked', 'a restored thread is locked again, as its lock stands' );
    _assert_action_recorded( $ctx, $restored->{action}, 'cleared' );

    my $unlocked = $store->unlock_thread( { %{$thread}, reason => 'calmer' } );
    ok( $unlocked->{ok}, 'thread unlock action succeeds' );
    $row = _row( $ctx, $THREAD_ROW_SQL, $ctx->{thread_id} );
    is( $row->{moderation_state}, 'visible',
        'thread is visible once unlocked' );
    is( $row->{locked_at}, undef, 'thread locked timestamp is cleared' );

    return;
}

sub _assert_action_recorded {
    my ( $ctx, $action, $reason ) = @_;

    my $type = $action->{action_type};
    my $id   = $action->{moderation_action_id};
    is( _row( $ctx, $ACTION_ROW_SQL, $id )->{action_type},
        $type, "$type is inserted as its own action row" );
    _assert_recorded_once( $ctx, $action, $type );
    is( _value( $ctx, $ACTION_AUDIT_REASON_SQL, $type, $id ),
        $reason, "$type creates an audit row with its reason" );

    return;
}

# One event, one outbox message and one audit row for the action, however
# often it was asked for.
sub _assert_recorded_once {
    my ( $ctx, $action, $label ) = @_;

    my $type = $action->{action_type};
    my $id   = $action->{moderation_action_id};
    my $key  = join q{:}, $type, @{$action}{qw(target_type target_id)}, $id;
    is( _value( $ctx, $KEYED_EVENTS_SQL, $key ),
        1, "$label: one $type domain event" );
    is( _value( $ctx, $KEYED_OUTBOX_SQL, $key ),
        1, "$label: one $type outbox handoff" );
    is( _value( $ctx, $ACTION_AUDITS_SQL, $type, $id ),
        1, "$label: one $type audit row" );

    return;
}

sub _reversal {
    my ($ctx) = @_;

    my $store     = _store( $ctx, 'GPForum::Service::Moderation::ActionStore' );
    my $action_id = $ctx->{hide_action_id};
    my $reviewer  = $ctx->{users}{reviewer};
    my $reversed =
      $store->reverse_action( $action_id, $reviewer, 'appeal accepted' );
    is( $reversed->{moderation_action_id},
        $action_id, 'reversal returns action id' );
    is( $reversed->{reversed_by_user_id}, $reviewer, 'reversal stores actor' );
    is( $reversed->{reversed_at},         $NOW, 'reversal stores timestamp' );

    my $row = _row( $ctx, $ACTION_ROW_SQL, $action_id );
    is( $row->{reversed_by_user_id},
        $reviewer, 'action row is marked reversed' );
    is( _utc( $ctx, $row->{reversed_at} ),
        $NOW, 'action row keeps the reversal time' );
    is( _value( $ctx, $EVENTS_SQL, 'moderation_action.reversed', $action_id ),
        1, 'moderation reversal creates a domain event' );
    is( _value( $ctx, $AGGREGATE_OUTBOX_SQL, $action_id ),
        1, 'moderation reversal creates outbox handoff' );
    is(
        _value(
            $ctx,                         $ACTION_AUDIT_REASON_SQL,
            'moderation_action.reversed', $action_id
        ),
        'appeal accepted',
        'reversal audit stores reason'
    );

    $ctx->{clock}->iso8601($AN_HOUR_ON);
    my $same =
      $store->reverse_action( $action_id, $reviewer, 'appeal accepted again' );
    $ctx->{clock}->iso8601($NOW);
    is( _utc( $ctx, $same->{reversed_at} ),
        $NOW, 'same reversal is idempotent' );
    is( _value( $ctx, $AGGREGATE_EVENTS_SQL, $action_id ),
        1, 'same reversal does not emit duplicate event' );
    is(
        _value(
            $ctx,                         $ACTION_AUDITS_SQL,
            'moderation_action.reversed', $action_id
        ),
        1,
        'same reversal does not write a second audit row'
    );

    return;
}

sub _command_replay {
    my ($ctx) = @_;

    my $store   = _store( $ctx, 'GPForum::Service::Moderation::ActionStore' );
    my %command = (
        actor_user_id => $ctx->{users}{moderator},
        command_id    => $ctx->{ids}->uuid,
        post_id       => $ctx->{post_id},
        reason        => 'spam again',
    );
    my $first = $store->hide_post( {%command} );
    my $again = $store->hide_post( {%command} );
    ok( $again->{replayed}, 'a repeated command replays' );
    is(
        $again->{action}{moderation_action_id},
        $first->{action}{moderation_action_id},
        'the action the command recorded'
    );
    is( _value( $ctx, $COMMAND_ACTIONS_SQL, $command{command_id} ),
        1, 'and records no second action' );
    _assert_recorded_once( $ctx, $first->{action}, 'after a replay' );

    return;
}

sub _audit_review {
    my ($ctx) = @_;

    my $review =
      GPForum::Service::Admin::AuditReview->new( schema => $ctx->{schema} );
    cmp_ok( _value( $ctx, $AUDIT_COUNT_SQL ),
        q{>}, $AUDIT_LIMIT, 'moderation left more audit rows than one page' );
    is( scalar @{ $review->recent( { limit => $AUDIT_LIMIT } ) },
        $AUDIT_LIMIT, 'audit review applies limit' );

    # Nearly every entry here has the clock's one created_at, so the page
    # boundaries fall on ties and only the audit_id arm of the keyset moves
    # the page on.
    my %target = ( target_id => $ctx->{post_id}, target_type => 'post' );
    my $walked = _walk(
        sub {
            my ($after) = @_;
            return $review->page( {%target},
                { after => $after, limit => $AUDIT_LIMIT } );
        },
        'audit_id'
    );
    cmp_ok( scalar @{$walked},
        q{>}, $AUDIT_LIMIT, 'target audit rows fill more than one page' );
    is_deeply(
        $walked,
        $ctx->{dbh}->selectcol_arrayref(
            $TARGET_AUDITS_SQL, undef, 'post', $ctx->{post_id}
        ),
        'target audit pages hold every row of the target once, newest first'
    );

    return;
}

sub _suspension_lifecycle {
    my ($ctx) = @_;

    my $store = _store( $ctx, 'GPForum::Service::Moderation::SuspensionStore' );
    my $member  = $ctx->{users}{member};
    my %suspend = (
        actor_user_id => $ctx->{users}{moderator},
        reason        => 'abuse campaign',
        user_id       => $member,
    );
    my $suspended =
      $store->create_suspension( { %suspend, valid_to => $TOMORROW } );
    ok( $suspended->{ok}, 'user suspension succeeds' );
    my $suspension_id = $suspended->{suspension}{suspension_id};
    ok( GPForum::Infrastructure::Id->is_uuid($suspension_id),
        'suspension id is generated' );
    is( $suspended->{suspension}{user_id},
        $member, 'suspension stores target user' );
    is( $suspended->{suspension}{valid_from},
        $NOW, 'suspension stores valid_from' );
    is( _row( $ctx, $USER_ROW_SQL, $member )->{status},
        'suspended', 'user status is suspended' );
    is( _value( $ctx, $USER_SUSPENSIONS_SQL, $member ),
        1, 'suspension row is inserted' );
    is( _value( $ctx, $EVENTS_SQL, 'user.suspended', $member ),
        1, 'suspension emits event' );
    is( _value( $ctx, $AGGREGATE_OUTBOX_SQL, $member ),
        1, 'suspension emits outbox handoff' );
    is( _value( $ctx, $AUDITS_SQL, 'user.suspended', $member ),
        1, 'suspension emits audit row' );

    my $same = $store->create_suspension( {%suspend} );
    is( $same->{suspension}{suspension_id},
        $suspension_id, 'same active suspension returns existing row' );
    is( _value( $ctx, $USER_SUSPENSIONS_SQL, $member ),
        1, 'same active suspension does not insert duplicate row' );
    is( _value( $ctx, $AGGREGATE_EVENTS_SQL, $member ),
        1, 'same active suspension does not emit duplicate event' );

    my $participation = $store->can_participate($member);
    ok( !$participation->{ok}, 'suspended user cannot participate' );
    is( $participation->{reason},
        'suspended', 'participation denial is explicit' );

    _revocation( $ctx, $store, $suspension_id );

    return;
}

sub _revocation {
    my ( $ctx, $store, $suspension_id ) = @_;

    my $member   = $ctx->{users}{member};
    my $reviewer = $ctx->{users}{reviewer};
    my $revoked =
      $store->revoke_suspension( $suspension_id, $reviewer, 'appeal accepted' );
    is( $revoked->{suspension_id},
        $suspension_id, 'suspension revocation returns suspension id' );
    is( $revoked->{revoked_at}, $NOW,
        'suspension revocation stores timestamp' );
    is( _row( $ctx, $USER_ROW_SQL, $member )->{status},
        'active', 'user status is restored after revocation' );
    is( _value( $ctx, $EVENTS_SQL, 'user.suspension_revoked', $member ),
        1, 'revocation event type is explicit' );
    is(
        _value( $ctx, $AUDIT_REASON_SQL, 'user.suspension_revoked', $member ),
        'appeal accepted',
        'revocation audit stores reason'
    );

    $ctx->{clock}->iso8601($AN_HOUR_ON);
    my $same = $store->revoke_suspension( $suspension_id, $reviewer,
        'appeal accepted again' );
    is( _utc( $ctx, $same->{revoked_at} ),
        $NOW, 'same revocation is idempotent' );
    is( _value( $ctx, $AGGREGATE_EVENTS_SQL, $member ),
        $REVOKE_EVENTS, 'same revocation does not emit duplicate event' );
    my $user = _row( $ctx, $USER_ROW_SQL, $member );
    is( $user->{status}, 'active',
        'already-revoked retry keeps an active user active' );
    is( _utc( $ctx, $user->{updated_at} ),
        $NOW, 'already-active user is not restamped on revoke retry' );

    $ctx->{dbh}->do( $SUSPEND_AGAIN_SQL, undef, $BEFORE, $member );
    my $retry = $store->revoke_suspension( $suspension_id, $reviewer,
        'appeal accepted again' );
    is( _utc( $ctx, $retry->{revoked_at} ),
        $NOW, 'incomplete restore retry keeps the original revoked timestamp' );
    $user = _row( $ctx, $USER_ROW_SQL, $member );
    is( $user->{status}, 'active',
        'incomplete restore retry restores a still-suspended user' );
    is( _utc( $ctx, $user->{updated_at} ),
        $NOW, 'incomplete restore retry uses the original revoked timestamp' );
    is( _value( $ctx, $AGGREGATE_EVENTS_SQL, $member ),
        $REVOKE_EVENTS,
        'incomplete restore retry does not emit a second revoke event' );
    $ctx->{clock}->iso8601($NOW);

    _missing_suspension_targets( $ctx, $store );

    return;
}

sub _missing_suspension_targets {
    my ( $ctx, $store ) = @_;

    my $before = _totals($ctx);
    is(
        $store->create_suspension(
            {
                actor_user_id => $ctx->{users}{moderator},
                reason        => 'missing',
                user_id       => $ctx->{ids}->uuid,
            }
        ),
        undef,
        'missing user cannot be suspended'
    );
    is(
        $store->revoke_suspension(
            $ctx->{ids}->uuid, $ctx->{users}{moderator}, 'missing'
        ),
        undef,
        'missing suspension cannot be revoked'
    );
    is_deeply( _totals($ctx), $before,
        'neither refusal writes a suspension, event, outbox or audit row' );

    return;
}

# The id the store mints is already a stored suspension's: the insert fails
# on suspensions_pkey inside the store's transaction, and the store has to
# roll back to its savepoint and try again with a new id.
sub _suspension_id_collision {
    my ($ctx) = @_;

    my $owner = _user( $ctx, 'collision_owner' );
    my $user  = _user( $ctx, 'collision_member' );
    my $taken = _suspend( $ctx, $owner, { valid_from => $NOW } );
    my $store = GPForum::Service::Moderation::SuspensionStore->new(
        clock      => $ctx->{clock},
        id_service => GPForum::Test::ScriptedId->new( next_ids => [$taken] ),
        schema     => $ctx->{schema},
    );
    my ( $suspended, $inserts ) = _inserts(
        $ctx,
        'suspensions',
        sub {
            return $store->create_suspension(
                {
                    actor_user_id => $ctx->{users}{moderator},
                    reason        => 'pk remint',
                    user_id       => $user,
                }
            );
        }
    );

    # Without this, a store that took its first uuid for something else
    # would never collide, and every check below would still pass.
    is( scalar @{$inserts}, 2, 'the store inserted twice' );
    like( $inserts->[0] // q{},
        qr/\Q$taken\E/msx, 'the first time with the id already taken' );
    ok( $suspended->{ok},
        'unique suspension id collision remints and suspends' );
    my $minted = $suspended->{suspension}{suspension_id} // q{};
    ok( GPForum::Infrastructure::Id->is_uuid($minted) && $minted ne $taken,
        'unique suspension id collision remints the id' );
    is( $suspended->{suspension}{user_id},
        $user, 'unique suspension id collision keeps this user' );
    is( _value( $ctx, $USER_SUSPENSIONS_SQL, $user ),
        1, 'unique suspension id collision inserts this suspension' );
    is( _row( $ctx, $SUSPENSION_ROW_SQL, $taken )->{user_id},
        $owner, 'the suspension holding the id is left alone' );
    is( _value( $ctx, $EVENTS_SQL, 'user.suspended', $user ),
        1, 'the remint records one suspension event' );

    return;
}

sub _participation {
    my ($ctx) = @_;

    my $store = _store( $ctx, 'GPForum::Service::Moderation::SuspensionStore' );
    my $deleted  = _user( $ctx, 'deleted_member', 'deleted' );
    my $decision = $store->can_participate($deleted);
    ok( !$decision->{ok}, 'deleted user cannot participate' );
    is( $decision->{reason},
        'user_deleted', 'deleted participation denial is explicit' );
    is( $store->can_participate( $ctx->{ids}->uuid )->{reason},
        'user_not_found', 'unknown user cannot participate' );

    my $open_user = _user( $ctx, 'open_suspension' );
    my $open      = _suspend( $ctx, $open_user, { valid_from => $TEN } );
    $decision = $store->can_participate($open_user);
    ok( !$decision->{ok}, 'active suspension blocks participation' );
    is( $decision->{suspension_id},
        $open, 'active suspension denial exposes id' );

    my $expired_user = _user( $ctx, 'expired_suspension' );
    _suspend( $ctx, $expired_user,
        { valid_from => $YESTERDAY, valid_to => $YESTERDAY_TO } );
    ok(
        $store->can_participate($expired_user)->{ok},
        'expired suspension does not block participation'
    );
    is( $store->active_for_user( $ctx->{ids}->uuid ),
        undef, 'missing user has no active suspension' );

    _suspension_ending_today( $ctx, $store );

    return;
}

# SuspensionStore decides in Perl whether valid_to has passed, comparing the
# column with the clock as strings. PostgreSQL returns '2026-05-23
# 18:00:00+00' (in the server's zone), the clock writes
# '2026-05-23T12:00:00Z', and a space sorts before a T: on its last day a
# suspension reads as expired, and a second create_suspension inserts
# another. ReviewReader asks PostgreSQL, and lists it as active.
sub _suspension_ending_today {
    my ( $ctx, $store ) = @_;

    my $user = _user( $ctx, 'ending_today' );
    my $id =
      _suspend( $ctx, $user, { valid_from => $BEFORE, valid_to => $TONIGHT } );
    is_deeply(
        _ids(
            _reader($ctx)->list_suspensions( { user_id => $user } )->{items},
            'suspension_id'
        ),
        [$id],
        'the review list shows a suspension ending later today as active'
    );

    local $TODO = 'SuspensionStore compares PostgreSQL timestamps as strings';
    my $active = $store->active_for_user($user);
    is( $active && $active->get_column('suspension_id'),
        $id, 'a suspension ending later today is active' );
    ok( !$store->can_participate($user)->{ok}, 'and blocks participation' );

    # Last: under the defect this suspends the user a second time.
    my $again = $store->create_suspension(
        {
            actor_user_id => $ctx->{users}{moderator},
            reason        => 'again',
            user_id       => $user,
        }
    );
    is( $again->{suspension}{suspension_id},
        $id, 'and suspending the user again returns it' );
    is( _value( $ctx, $USER_SUSPENSIONS_SQL, $user ),
        1, 'without a second suspension' );

    return;
}

sub _action_history {
    my ($ctx) = @_;

    my $reader = _reader($ctx);
    my $post   = $ctx->{ids}->uuid;

    # The first row carries the post's id but is a thread's action, and is
    # newer than all of the post's: only the target_type filter keeps it out.
    my @rows = (
        [ $ctx->{ids}->uuid, 'thread.locked', 'thread', $post,   $AN_HOUR_ON ],
        [ $NEWEST,           'post.hidden',   'post',   $post,   $NOW ],
        [ $TIED_HIGH,        'post.restored', 'post',   $post,   $BEFORE ],
        [ $TIED_LOW,         'post.hidden',   'post',   $post,   $BEFORE ],
        [ $OTHER,  'thread.locked', 'thread', $ctx->{ids}->uuid, $HALF_PAST ],
        [ $OLDEST, 'post.restored', 'post',   $post,             $TEN ],
    );
    for my $row (@rows) {
        $ctx->{dbh}
          ->do( $ACTION_SQL, undef, @{$row}, $ctx->{users}{moderator} );
    }

    my %target = ( target_id => $post, target_type => 'post' );
    my $page   = $reader->list_actions( { %target, limit => 2 } );
    is_deeply(
        _ids( $page->{items}, 'moderation_action_id' ),
        [ $NEWEST, $TIED_HIGH ],
        'moderation action history filters the target, newest first'
    );
    ok( $page->{next_cursor}, 'moderation action history exposes cursor' );
    my $next = $reader->list_actions(
        { %target, after => $page->{next_cursor}, limit => 2 } );
    is_deeply(
        _ids( $next->{items}, 'moderation_action_id' ),
        [ $TIED_LOW, $OLDEST ],
        'moderation action history uses descending cursor predicate'
    );
    ok( !$next->{next_cursor}, 'a full last page has no cursor' );

    my $whole = $reader->list_actions( { %target, limit => $TARGET_ACTIONS } );
    is( scalar @{ $whole->{items} },
        $TARGET_ACTIONS, 'moderation action history applies page size' );
    is( $whole->{has_next}, 0,
        'moderation action history fetches one extra row to know' );

    my $forged =
      $reader->list_actions( { %target, after => $NOT_CURSOR, limit => 2 } );
    is_deeply(
        _ids( $forged->{items}, 'moderation_action_id' ),
        [ $NEWEST, $TIED_HIGH ],
        'a cursor that is not one shows the first page'
    );

    _whole_action_history( $ctx, $reader );

    return;
}

# Paged one row at a time, across the clock's many actions at one instant.
sub _whole_action_history {
    my ( $ctx, $reader ) = @_;

    my $walked = _walk(
        sub {
            my ($after) = @_;
            return $reader->list_actions( { after => $after, limit => 1 } );
        },
        'moderation_action_id'
    );
    is_deeply(
        $walked,
        $ctx->{dbh}->selectcol_arrayref($ALL_ACTIONS_SQL),
        'moderation action history pages hold every action once'
    );

    return;
}

sub _suspension_history {
    my ($ctx) = @_;

    my $reader = _reader($ctx);
    my $user   = _user( $ctx, 'history_member' );
    my $open   = _suspend( $ctx, $user, { valid_from => $BEFORE } );
    my $bounded =
      _suspend( $ctx, $user, { valid_from => $TEN, valid_to => $TOMORROW } );
    my $revoked = _suspend( $ctx, $user,
        { revoked_at => $NINE_THIRTY, valid_from => $NINE } );
    my $expired =
      _suspend( $ctx, $user, { valid_from => $EIGHT, valid_to => $NINE } );
    _suspend(
        $ctx,
        _user( $ctx, 'history_other' ),
        { valid_from => $HALF_PAST }
    );

    my $page = $reader->list_suspensions( { limit => 1, user_id => $user } );
    is_deeply( _ids( $page->{items}, 'suspension_id' ),
        [$open], 'suspension review applies keyset page size and user' );
    ok( $page->{next_cursor}, 'suspension review exposes cursor' );
    my $next = $reader->list_suspensions(
        { after => $page->{next_cursor}, limit => 1, user_id => $user } );
    is_deeply( _ids( $next->{items}, 'suspension_id' ),
        [$bounded],
        'suspension review defaults to active rows, not revoked or expired' );
    ok( !$next->{next_cursor}, 'and ends with them' );

    my @everything = ( $open, $bounded, $revoked, $expired );
    for my $mode ( { status => 'all' }, { active => 0 } ) {
        my $listed = $reader->list_suspensions(
            { %{$mode}, limit => $HISTORY_LIMIT, user_id => $user } );
        is_deeply( _ids( $listed->{items}, 'suspension_id' ),
            \@everything,
            'suspension review can include revoked rows, newest first' );
    }

    return;
}

# One user's suspensions that all start at one instant, so only the
# suspension_id arm of the keyset moves the page on; the last one ends at the
# clock's very instant, which still counts as active (valid_to >= now, as t/25
# pinned on the fake ORM).
sub _suspension_ties {
    my ($ctx) = @_;

    my $reader = _reader($ctx);
    my $user   = _user( $ctx, 'tied_member' );
    for ( 1 .. $TIED_STARTS ) {
        _suspend( $ctx, $user, { valid_from => $TEN } );
    }
    my $ending =
      _suspend( $ctx, $user, { valid_from => $TEN, valid_to => $NOW } );

    my $listed = $reader->list_suspensions(
        { limit => $HISTORY_LIMIT, user_id => $user } );
    ok(
        (
            grep { $_ eq $ending }
              @{ _ids( $listed->{items}, 'suspension_id' ) }
        ),
        'a suspension ending at this very instant is still listed as active'
    );

    my $walked = _walk(
        sub {
            my ($after) = @_;
            return $reader->list_suspensions(
                { after => $after, limit => 1, user_id => $user } );
        },
        'suspension_id'
    );
    is_deeply(
        $walked,
        $ctx->{dbh}
          ->selectcol_arrayref( $USER_SUSPENSION_IDS_SQL, undef, $user ),
'suspension review pages hold every one once, through ties on valid_from'
    );

    return;
}

sub _suspend {
    my ( $ctx, $user_id, $period ) = @_;

    my $id = $ctx->{ids}->uuid;
    $ctx->{dbh}->do(
        $SUSPENSION_SQL, undef, $id, $user_id,
        $ctx->{users}{moderator},
        @{$period}{qw(valid_from valid_to revoked_at)}
    );

    return $id;
}

sub _store {
    my ( $ctx, $class ) = @_;

    return $class->new(
        clock      => $ctx->{clock},
        id_service => $ctx->{ids},
        schema     => $ctx->{schema},
    );
}

sub _reader {
    my ($ctx) = @_;

    return GPForum::Service::Moderation::ReviewReader->new(
        clock  => $ctx->{clock},
        schema => $ctx->{schema},
    );
}

# Every row of a keyset list, a page at a time.
sub _walk {
    my ( $read, $column ) = @_;

    my $page  = $read->(undef);
    my @ids   = @{ _page_ids( $page, $column ) };
    my $pages = 1;
    while ( $page->{next_cursor} && $pages < $MAX_PAGES ) {
        $page = $read->( $page->{next_cursor} );
        push @ids, @{ _page_ids( $page, $column ) };
        $pages++;
    }

    return \@ids;
}

sub _page_ids {
    my ( $page, $column ) = @_;

    return _ids( $page->{items} // $page->{rows}, $column );
}

sub _ids {
    my ( $rows, $column ) = @_;

    return [ map { $_->get_column($column) } @{$rows} ];
}

sub _utc {
    my ( $ctx, $timestamp ) = @_;

    return _value( $ctx, $UTC_SQL, $timestamp );
}

sub _row {
    my ( $ctx, $sql, @bind ) = @_;

    return $ctx->{dbh}->selectrow_hashref( $sql, undef, @bind ) // {};
}

sub _value {
    my ( $ctx, $sql, @bind ) = @_;

    return scalar $ctx->{dbh}->selectrow_array( $sql, undef, @bind );
}

sub _totals {
    my ($ctx) = @_;

    return [ map { _value( $ctx, $_ ) } @TOTAL_SQLS ];
}

# The INSERT statements into $table that $code sends, as DBIx::Class traces
# them: one PostgreSQL refused and the store rolled back leaves no row to
# count.
sub _inserts {
    my ( $ctx, $table, $code ) = @_;

    my $storage = $ctx->{schema}->storage;
    my @inserts;
    $storage->debugcb(
        sub {
            my ( $operation, $statement ) = @_;
            if ( $statement =~ /\A INSERT [ ] INTO [ ] "?\Q$table\E"? [ ]/msx )
            {
                push @inserts, $statement;
            }
            return;
        }
    );
    $storage->debug(1);
    my $result = $code->();
    $storage->debug(0);
    $storage->debugcb(undef);

    return ( $result, \@inserts );
}

1;
