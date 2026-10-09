# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use Mojo::JSON qw(encode_json);
use Mojo::Log;
use POSIX qw(strftime);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::Id;
use GPForum::Service::Notification::Dispatcher;
use GPForum::Service::Notification::PreferenceStore;
use GPForum::Service::Notification::RecipientPolicy;
use GPForum::Service::Notification::SubscriptionStore;
use GPForum::Service::Outbox::Dispatcher;
use GPForum::Service::Outbox::DomainEventTransport;
use GPForum::Service::Realtime::Hub;
use GPForum::Service::Realtime::PgNotifier;
use GPForum::Test::BadgeBroadcastSpy;
use GPForum::Test::InterleavedClock;
use GPForum::Test::OpenTransaction;
use GPForum::Test::PgDatabase;
use GPForum::Test::PostgresHarness;
use GPForum::Test::RealtimeConnection;
use GPForum::Test::ScriptedId;
use GPForum::Worker::Handler::NotificationDispatch;

our $VERSION = '0.001';

const my $NOW     => '2026-05-23T12:00:00Z';
const my $LATER   => '2026-05-23T13:00:00Z';
const my $EARLIER => '2026-05-23T11:00:00Z';

# Inside this UTC month's partition, which migrating creates (ADR 0113); the
# times above fall in notifications_default.
const my $IN_THIS_MONTH => strftime( '%Y-%m-15T12:00:00Z', gmtime );

const my $LIST_LIMIT          => 10;
const my $LISTED              => 3;
const my $READ_ROWS           => 3;
const my $UNCOUNTED_BADGES    => 3;
const my $PREFERENCE_CHANNELS => 3;
const my $OPEN_SOURCES        => 3;
const my $HIDDEN_SOURCES      => 2;
const my $ALL_SOURCES         => 5;
const my $UNREAD_CAP          => 100;
const my $BACKLOG             => 120;
const my $OUTBOX_BATCH        => 10;
const my $MAX_PAGES           => 50;

const my @MEMBERS => qw(
  reader other author muted raced orphan racer hidden backlog
  badge rollback counted fanned unsent
);

const my $USER_SQL => join q{ },
  'INSERT INTO users (id, username, display_name, email_normalized,',
  q{password_hash, status) VALUES (?, ?, ?, ?, 'x', 'active')};
const my $SPACE_SQL => join q{ },
  'INSERT INTO spaces (space_id, slug, title)',
  q{VALUES (?, 'notifications', 'Notifications')};
const my $CATEGORY_SQL => join q{ },
  'INSERT INTO categories (category_id, space_id, slug, title, visibility)',
  'VALUES (?, ?, ?, ?, ?)';
const my $THREAD_SQL => join q{ },
  'INSERT INTO threads (thread_id, category_id, author_user_id, title, slug)',
  'VALUES (?, ?, ?, ?, ?)';
const my $POST_SQL => join q{ },
  'INSERT INTO posts (post_id, thread_id, author_user_id, position)',
  'VALUES (?, ?, ?, ?)';
const my $SUBSCRIPTION_SQL => join q{ },
  'INSERT INTO subscriptions (subscription_id, user_id, target_type,',
  q{target_id, created_at) VALUES (?, ?, 'thread', ?, ?)};
const my $PREFERENCE_SQL => join q{ },
  'INSERT INTO notification_preferences (user_id, channel, enabled,',
  'digest_frequency, updated_at) VALUES (?, ?, ?, ?, ?)';
const my $NOTIFICATION_SQL => join q{ },
  'INSERT INTO notifications (notification_id, recipient_user_id,',
  'source_type, source_id, notification_type, created_at)',
  q{VALUES (?, ?, 'post', ?, 'reply', ?)};
const my $INBOX_SQL => join q{ },
  'INSERT INTO notification_inbox (recipient_user_id, notification_id,',
  'created_at) VALUES (?, ?, ?)';

# Due a minute ago: the outbox claims what is due by its clock, whole
# seconds, and now() written this second would still be ahead of it.
const my $OUTBOX_SQL => join q{ },
  'INSERT INTO outbox_messages (outbox_id, event_id, queue, job_type,',
  q{idempotency_key, payload, next_attempt_at) VALUES (?, ?, 'events',},
  q{'domain_event.dispatch', ?, ?::jsonb, now() - interval '1 minute')};

# A hundred and twenty unread notifications, one second apart.
const my $BACKLOG_SQL => join q{ },
  'INSERT INTO notifications (notification_id, recipient_user_id,',
  'source_type, source_id, notification_type, created_at)',
  q{SELECT gen_random_uuid(), ?, 'post', ?, 'reply',},
  '?::timestamptz - make_interval(secs => n)',
  'FROM generate_series(1, ?) AS n';
const my $BACKLOG_INBOX_SQL => join q{ },
  'INSERT INTO notification_inbox (recipient_user_id, notification_id,',
  'created_at) SELECT recipient_user_id, notification_id, created_at',
  'FROM notifications WHERE recipient_user_id = ?';

# The test's own refusals, in its own clone: a row PostgreSQL rejects, and
# a commit it rejects at COMMIT, after every statement has succeeded.
const my $REFUSE_SOURCE_SQL => join q{ },
  'ALTER TABLE notifications ADD CONSTRAINT test_refused_source',
  'CHECK (source_id IS DISTINCT FROM %s::uuid)';
const my $REFUSE_COMMIT_FUNCTION_SQL => join "\n",
  'CREATE FUNCTION test_refuse_commit() RETURNS trigger',
  'LANGUAGE plpgsql AS $$',
  q{BEGIN RAISE EXCEPTION 'commit refused'; END},
  q{$$};
const my $REFUSE_COMMIT_TRIGGER_SQL => join q{ },
  'CREATE CONSTRAINT TRIGGER test_refuse_commit',
  'AFTER INSERT ON notification_inbox',
  'DEFERRABLE INITIALLY DEFERRED FOR EACH ROW',
  'WHEN (NEW.recipient_user_id = %s::uuid)',
  'EXECUTE FUNCTION test_refuse_commit()';

const my $SUBSCRIPTION_ROWS_SQL => join q{ },
  'SELECT count(*) FROM subscriptions',
  q{WHERE user_id = ? AND target_type = 'thread' AND target_id = ?};
const my $SUBSCRIPTION_ROW_SQL =>
  'SELECT * FROM subscriptions WHERE subscription_id = ?';
const my $PREFERENCE_ROWS_SQL =>
  'SELECT count(*) FROM notification_preferences WHERE user_id = ?';
const my $NOTIFICATION_ROWS_SQL =>
  'SELECT count(*) FROM notifications WHERE recipient_user_id = ?';
const my $NOTIFICATION_ID_ROWS_SQL =>
  'SELECT count(*) FROM notifications WHERE notification_id = ?';
const my $SOURCE_ROWS_SQL =>
  'SELECT count(*) FROM notifications WHERE source_id = ?';
const my $INBOX_ROWS_SQL =>
  'SELECT count(*) FROM notification_inbox WHERE recipient_user_id = ?';
const my $INBOX_ROW_SQL => join q{ },
  'SELECT * FROM notification_inbox',
  'WHERE recipient_user_id = ? AND notification_id = ?';
const my $INBOX_NOTIFICATION_SQL => join q{ },
  'SELECT count(*) FROM notification_inbox AS inbox',
  'JOIN notifications AS notification',
  'USING (notification_id, created_at)',
  'WHERE inbox.recipient_user_id = ? AND inbox.notification_id = ?';
const my $INBOX_ORDER_SQL => join q{ },
  'SELECT notification_id FROM notification_inbox',
  'WHERE recipient_user_id = ?',
  'ORDER BY created_at DESC, notification_id DESC';
const my $UNREAD_SQL => join q{ },
  'UPDATE notification_inbox SET read_at = NULL',
  'WHERE recipient_user_id = ? AND notification_id = ?';
const my $READ_ROWS_SQL =>
  'SELECT count(*) FROM notification_reads WHERE recipient_user_id = ?';
const my $OUTBOX_STATUS_SQL =>
  'SELECT status FROM outbox_messages WHERE outbox_id = ?';
const my $OUTBOX_RETRY_SQL => join q{ },
  q{UPDATE outbox_messages SET status = 'pending',},
  q{next_attempt_at = now() - interval '1 minute' WHERE outbox_id = ?};
const my $CATEGORY_VISIBILITY_SQL =>
  'UPDATE categories SET visibility = ? WHERE category_id = ?';
const my $LOCK_POSTS_SQL         => 'LOCK TABLE posts IN ACCESS EXCLUSIVE MODE';
const my $SHORT_LOCK_TIMEOUT_SQL => q{SET lock_timeout = '100ms'};

# A timestamp as the clock writes it, whatever zone the server returns it in.
const my $UTC_SQL => join q{ },
  q{SELECT to_char(?::timestamptz AT TIME ZONE 'UTC',},
  q{'YYYY-MM-DD"T"HH24:MI:SS"Z"')};

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# Notifications on PostgreSQL: subscriptions, preferences, delivery and its
# fan-out from the outbox, the inbox's keyset pages, reads, the unread count
# and its badge. These ran on a fake ORM in t/17, which took any string for
# a uuid, gave back timestamps as they were written, and could not see that
# PostgreSQL names a partition's index, not the table's, in a conflict.
my $clone         = GPForum::Test::PgDatabase->fresh;
my $notifications = _context($clone);

_subscriptions($notifications);
_subscription_id_collision($notifications);
_subscription_races($notifications);
_preferences($notifications);
_preference_race($notifications);
_delivery($notifications);
_raced_delivery($notifications);
_leftover_notification($notifications);
_leftover_at_another_time($notifications);
_raced_delivery_at_another_time($notifications);
_refused_delivery($notifications);
_fanout($notifications);
_outbox_fanout($notifications);
_degraded_fanout($notifications);
_inbox_listing($notifications);
_inbox_pages($notifications);
_mark_read($notifications);
_mark_all_read($notifications);
_readable_inbox($notifications);
_unread_cap($notifications);
_badge_after_commit($notifications);
_badge_count_failures($notifications);
_refused_notify($notifications);
$notifications->{peer}->disconnect;

done_testing();

sub _context {
    my ($database) = @_;

    my $ctx = {
        clock  => GPForum::Test::InterleavedClock->new,
        dbh    => $database->dbh,
        ids    => GPForum::Infrastructure::Id->new,
        peer   => GPForum::Test::PostgresHarness::connect_dbi( $database->dsn ),
        schema => $database->schema,
    };
    $ctx->{users} = { map { $_ => _user( $ctx, $_ ) } @MEMBERS };
    _forum($ctx);
    $ctx->{policy} = GPForum::Service::Notification::RecipientPolicy->new(
        schema => $ctx->{schema} );
    $ctx->{subscriptions} =
      GPForum::Service::Notification::SubscriptionStore->new(
        clock  => $ctx->{clock},
        schema => $ctx->{schema},
      );
    $ctx->{preferences} = GPForum::Service::Notification::PreferenceStore->new(
        clock  => $ctx->{clock},
        schema => $ctx->{schema},
    );

    return $ctx;
}

sub _user {
    my ( $ctx, $name ) = @_;

    my $id = $ctx->{ids}->uuid;
    $ctx->{dbh}->do(
        $USER_SQL, undef, $id, "${name}_notified",
        ucfirst $name,
        "$name.notified\@example.test"
    );

    return $id;
}

# A public category with two threads, a club category that later turns
# private, and a private staff room none of the members has a grant for.
sub _forum {
    my ($ctx) = @_;

    my $space = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $SPACE_SQL, undef, $space );
    my %category = (
        open  => 'public',
        club  => 'public',
        staff => 'private',
    );
    for my $name ( sort keys %category ) {
        my $category = $ctx->{ids}->uuid;
        $ctx->{dbh}
          ->do( $CATEGORY_SQL, undef, $category, $space, $name, ucfirst $name,
            $category{$name} );
        $ctx->{categories}{$name} = $category;
    }

    $ctx->{thread_id}    = _thread( $ctx, 'open', 'followed' );
    $ctx->{other_thread} = _thread( $ctx, 'open', 'elsewhere' );
    $ctx->{club_thread}  = _thread( $ctx, 'club', 'members' );
    $ctx->{staff_post}   = _post( $ctx, _thread( $ctx, 'staff', 'staff' ) );

    return;
}

sub _thread {
    my ( $ctx, $category, $slug ) = @_;

    my $id = $ctx->{ids}->uuid;
    $ctx->{dbh}->do(
        $THREAD_SQL, undef, $id,
        $ctx->{categories}{$category},
        $ctx->{users}{author},
        ucfirst $slug, $slug
    );

    return $id;
}

sub _post {
    my ( $ctx, $thread ) = @_;

    my $id = $ctx->{ids}->uuid;
    $ctx->{positions}{$thread} += 1;
    $ctx->{dbh}->do(
        $POST_SQL, undef, $id, $thread,
        $ctx->{users}{author},
        $ctx->{positions}{$thread}
    );

    return $id;
}

sub _subscriptions {
    my ($ctx) = @_;

    my $store  = $ctx->{subscriptions};
    my $reader = $ctx->{users}{reader};
    my %target = (
        target_id   => $ctx->{thread_id},
        target_type => 'thread',
        user_id     => $reader,
    );
    my $subscription = $store->subscribe( {%target} );
    my $id           = $subscription->{subscription_id};

    ok( GPForum::Infrastructure::Id->is_uuid($id),
        'subscription id is generated' );
    is( $subscription->{user_id}, $reader, 'subscription stores user' );
    is( $subscription->{target_type},
        'thread', 'subscription stores target type' );
    is( $subscription->{target_id},
        $ctx->{thread_id}, 'subscription stores target id' );
    is( $subscription->{preference}, 'all',
        'subscription defaults preference' );
    is( $subscription->{created_at},
        $NOW, 'subscription stores creation time' );
    is( _value( $ctx, $SUBSCRIPTION_ROWS_SQL, $reader, $ctx->{thread_id} ),
        1, 'subscription row is created' );
    is( _utc( $ctx, _row( $ctx, $SUBSCRIPTION_ROW_SQL, $id )->{created_at} ),
        $NOW, 'subscription row keeps the creation time' );

    my $status =
      $store->status_for_user_target( $reader, 'thread', $ctx->{thread_id} );
    is( $status->{subscribed},      1,   'subscription status is active' );
    is( $status->{muted},           0,   'subscription status starts unmuted' );
    is( $status->{subscription_id}, $id, 'subscription status exposes id' );

    my $saved =
      $store->save_subscription( { %target, preference => 'mentions' } );
    is( $saved->{subscription_id},
        $id, 'saving an existing subscription is idempotent' );
    is( $saved->{preference},
        'mentions', 'idempotent subscription save updates preference' );
    is( _row( $ctx, $SUBSCRIPTION_ROW_SQL, $id )->{preference},
        'mentions', 'and stores it' );
    is( _value( $ctx, $SUBSCRIPTION_ROWS_SQL, $reader, $ctx->{thread_id} ),
        1, 'idempotent subscription save does not insert a duplicate' );

    my ( $saved_again, $save_updates ) = _sent(
        $ctx, 'UPDATE',
        'subscriptions',
        sub {
            return $store->save_subscription(
                { %target, preference => 'mentions' } );
        }
    );
    ok( $saved_again->{skipped},
        'already-active subscription save is skipped' );
    is( $saved_again->{preference},
        'mentions', 'already-active subscription keeps the preference' );
    is( scalar @{$save_updates},
        0, 'already-active subscription does not update the row' );

    _mute_and_revoke( $ctx, $id, \%target );

    is_deeply( [ $store->subscribers_for( 'thread', $ctx->{thread_id} ) ],
        [$reader], 'subscribers can be listed' );

    return;
}

# Each stamp is written once: asked again an hour later, the store answers
# with the first one and sends no UPDATE.
sub _mute_and_revoke {
    my ( $ctx, $id, $target ) = @_;

    my $store = $ctx->{subscriptions};
    my ( $muted, $first_updates ) =
      _sent( $ctx, 'UPDATE', 'subscriptions',
        sub { return $store->mute($id) } );
    is( $muted->{muted_at},       $NOW, 'subscription can be muted' );
    is( scalar @{$first_updates}, 1,    'with one UPDATE' );
    my ( $muted_again, $mute_updates ) =
      _stamped_again( $ctx, sub { return $store->mute($id) } );
    ok( $muted_again->{skipped}, 'already-muted subscription is skipped' );
    is( _utc( $ctx, $muted_again->{muted_at} ),
        $NOW, 'already-muted subscription keeps the original timestamp' );
    is( scalar @{$mute_updates},
        0, 'already-muted subscription does not update the row' );

    my $revoked = $store->revoke($id);
    is( $revoked->{revoked_at}, $NOW, 'subscription can be revoked' );
    is(
        $store->status_for_user_target( $target->{user_id}, 'thread',
            $target->{target_id} )->{subscribed},
        0,
        'revoked subscription status is inactive'
    );

    my $restored =
      $store->save_subscription( { %{$target}, preference => 'all' } );
    is( $restored->{subscription_id},
        $id, 'save restores revoked subscription' );
    is( _row( $ctx, $SUBSCRIPTION_ROW_SQL, $id )->{revoked_at},
        undef, 'restored subscription clears revocation' );

    my $target_muted = $store->mute_for_user_target( { %{$target} } );
    ok( $target_muted->{ok}, 'subscription can be muted by target' );
    is( $target_muted->{muted_at}, $NOW, 'target mute records timestamp' );
    my ( $target_muted_again, $target_mute_updates ) = _stamped_again( $ctx,
        sub { return $store->mute_for_user_target( { %{$target} } ) } );
    ok( $target_muted_again->{skipped},
        'already-muted target subscription is skipped' );
    is( _utc( $ctx, $target_muted_again->{muted_at} ),
        $NOW,
        'already-muted target subscription keeps the original timestamp' );
    is( scalar @{$target_mute_updates},
        0, 'already-muted target subscription does not update the row' );

    my $unmuted =
      $store->save_subscription( { %{$target}, preference => 'all' } );
    is( $unmuted->{preference},
        'all', 'save restores muted subscription preference' );
    is( _row( $ctx, $SUBSCRIPTION_ROW_SQL, $id )->{muted_at},
        undef, 'save clears muted state' );

    my $target_revoked = $store->revoke_for_user_target( { %{$target} } );
    ok( $target_revoked->{ok}, 'subscription can be revoked by target' );
    is( $target_revoked->{revoked_at}, $NOW,
        'target revoke records timestamp' );
    my ( $target_revoked_again, $target_revoke_updates ) = _stamped_again(
        $ctx,
        sub {
            return $store->revoke_for_user_target( { %{$target} } );
        }
    );
    ok( $target_revoked_again->{skipped},
        'already-revoked target subscription is skipped' );
    is( _utc( $ctx, $target_revoked_again->{revoked_at} ),
        $NOW,
        'already-revoked target subscription keeps the original timestamp' );
    is( scalar @{$target_revoke_updates},
        0, 'already-revoked target subscription does not update the row' );

    $store->save_subscription( { %{$target}, preference => 'all' } );
    my $active = _row( $ctx, $SUBSCRIPTION_ROW_SQL, $id );
    is( $active->{muted_at},   undef, 'active restore clears mute' );
    is( $active->{revoked_at}, undef, 'active restore clears revocation' );

    return;
}

sub _stamped_again {
    my ( $ctx, $code ) = @_;

    return _sent( $ctx, 'UPDATE', 'subscriptions',
        sub { return _at( $ctx, $LATER, $code ) } );
}

# The id the store mints is taken by another member's subscription:
# PostgreSQL refuses it on subscriptions_pkey and the store mints another.
sub _subscription_id_collision {
    my ($ctx) = @_;

    my $taken = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $SUBSCRIPTION_SQL, undef, $taken, $ctx->{users}{other},
        $ctx->{ids}->uuid, $NOW );
    my $store = GPForum::Service::Notification::SubscriptionStore->new(
        clock      => $ctx->{clock},
        id_service => GPForum::Test::ScriptedId->new( next_ids => [$taken] ),
        schema     => $ctx->{schema},
    );
    my $target = $ctx->{ids}->uuid;
    my $saved  = $store->save_subscription(
        {
            target_id   => $target,
            target_type => 'thread',
            user_id     => $ctx->{users}{reader},
        }
    );

    ok( !$saved->{skipped},
        'unique subscription id collision remints and saves' );
    ok(
        $saved->{subscription_id} ne $taken
          && GPForum::Infrastructure::Id->is_uuid( $saved->{subscription_id} ),
        'unique subscription id collision remints the id'
    );
    is(
        $saved->{user_id},
        $ctx->{users}{reader},
        'unique subscription id collision keeps this user'
    );
    is( $saved->{target_id}, $target,
        'unique subscription id collision keeps this target' );
    is(
        _row( $ctx, $SUBSCRIPTION_ROW_SQL, $taken )->{user_id},
        $ctx->{users}{other},
        'and leaves the other subscription alone'
    );

    return;
}

# Another writer commits this member's subscription between the store's
# lookup and its insert.
sub _subscription_races {
    my ($ctx) = @_;

    my $reader   = $ctx->{users}{reader};
    my $leftover = $ctx->{ids}->uuid;
    my $target   = $ctx->{ids}->uuid;
    my $store    = GPForum::Service::Notification::SubscriptionStore->new(
        clock      => $ctx->{clock},
        id_service => GPForum::Test::ScriptedId->new( next_ids => [$leftover] ),
        schema     => $ctx->{schema},
    );
    my $saved = _racing(
        $ctx,
        sub {
            return
              shift->do( $SUBSCRIPTION_SQL, undef, $leftover, $reader,
                $target, $NOW );
        },
        sub {
            return $store->save_subscription(
                {
                    target_id   => $target,
                    target_type => 'thread',
                    user_id     => $reader,
                }
            );
        }
    );
    ok( $saved->{skipped},
        'leftover subscription id race reuses this subscription' );
    is( $saved->{subscription_id},
        $leftover, 'leftover subscription id race keeps this subscription' );
    is( $saved->{user_id}, $reader,
        'leftover subscription id race keeps this user' );
    is( _value( $ctx, $SUBSCRIPTION_ROWS_SQL, $reader, $target ),
        1,
        'leftover subscription id race does not insert a second subscription' );

    # Two requests subscribing at once: the other's row, under its own id,
    # is the one kept.
    my $winner       = $ctx->{ids}->uuid;
    my $raced_target = $ctx->{ids}->uuid;
    my $raced        = _racing(
        $ctx,
        sub {
            return
              shift->do( $SUBSCRIPTION_SQL, undef, $winner, $reader,
                $raced_target, $NOW );
        },
        sub {
            return $ctx->{subscriptions}->save_subscription(
                {
                    target_id   => $raced_target,
                    target_type => 'thread',
                    user_id     => $reader,
                }
            );
        }
    );
    ok( $raced->{skipped},
        'a subscription raced on its target reuses the row' );
    is( $raced->{subscription_id}, $winner, 'keeping the winner\'s id' );
    is( _value( $ctx, $SUBSCRIPTION_ROWS_SQL, $reader, $raced_target ),
        1, 'and one row' );

    return;
}

sub _preferences {
    my ($ctx) = @_;

    my $store  = $ctx->{preferences};
    my $reader = $ctx->{users}{reader};
    my %email  = (
        channel          => 'email',
        digest_frequency => 'daily',
        enabled          => 1,
        user_id          => $reader,
    );
    my $preference = $store->set_preference( {%email} );
    is( $preference->{user_id}, $reader, 'preference stores user' );
    is( $preference->{channel}, 'email', 'preference stores channel' );
    is( $preference->{enabled}, 1,       'preference stores enabled flag' );
    is( $preference->{digest_frequency},
        'daily', 'preference stores digest frequency' );
    is( $preference->{updated_at}, $NOW, 'preference stores update time' );
    is( _value( $ctx, $PREFERENCE_ROWS_SQL, $reader ),
        1, 'preference row is upserted' );

    my ( $same, $updates ) = _sent(
        $ctx, 'UPDATE',
        'notification_preferences',
        sub {
            return _at( $ctx, $LATER,
                sub { return $store->set_preference( {%email} ) } );
        }
    );
    ok( $same->{skipped},
        'already-applied notification preference is skipped' );
    is(
        _utc( $ctx, $same->{updated_at} ),
        $NOW,
        'already-applied notification preference keeps the original timestamp'
    );
    is( scalar @{$updates},
        0, 'already-applied notification preference does not update the row' );

    is_deeply(
        [ $store->enabled_channels($reader) ],
        [ 'in_app', 'email' ],
        'enabled channels read the stored rows over the defaults'
    );
    is_deeply(
        [ $store->enabled_channels( $ctx->{ids}->uuid ) ],
        [ 'in_app', 'email' ],
        'a member who never saved preferences has the default channels on'
    );

    _refused_channels( $ctx, $reader );
    _preference_page( $ctx, $reader );

    return;
}

# A misspelt channel was written as in_app: meant for email, it turned the
# member's in-app notifications off.
sub _refused_channels {
    my ( $ctx, $reader ) = @_;

    my $store    = $ctx->{preferences};
    my $stored   = _value( $ctx, $PREFERENCE_ROWS_SQL, $reader );
    my $misspelt = $store->set_preference(
        {
            channel          => 'emial',
            digest_frequency => 'daily',
            enabled          => 0,
            user_id          => $reader,
        }
    );
    ok( !$misspelt->{ok}, 'a misspelt channel is refused' );
    is( $misspelt->{status}, 'invalid', 'as invalid input' );
    ok( $misspelt->{errors}{channel}, 'naming the channel field' );
    is( _value( $ctx, $PREFERENCE_ROWS_SQL, $reader ),
        $stored, 'and nothing is written for it' );
    ok( $store->channel_enabled( $reader, 'in_app' ),
        'in-app notifications stay on' );

    my $misspelt_batch = $store->set_preferences(
        {
            preferences => [
                {
                    channel          => 'email',
                    digest_frequency => 'weekly',
                    enabled          => 0,
                },
                {
                    channel          => 'in-app',
                    digest_frequency => 'immediate',
                    enabled          => 0,
                },
            ],
            user_id => $reader,
        }
    );
    is( ref $misspelt_batch,
        'HASH', 'a batch with a misspelt channel is refused' );
    is( $misspelt_batch->{status}, 'invalid', 'as invalid input' );
    ok(
        $store->channel_enabled( $reader, 'email' ),
        'and its valid rows are not written either'
    );

    return;
}

sub _preference_page {
    my ( $ctx, $reader ) = @_;

    my $store = $ctx->{preferences};
    my $page  = $store->preferences_for_user($reader);
    is( scalar @{$page},
        $PREFERENCE_CHANNELS,
        'preference page exposes every supported channel' );
    is( $page->[0]{channel},
        'in_app', 'preference page has stable channel order' );
    is( $page->[1]{enabled},
        1, 'stored email preference overlays channel defaults' );
    is( $page->[2]{enabled}, 0, 'digest channel defaults to disabled' );
    is(
        $page->[0]{label_key},
        'notifications.channel.in_app',
        'preference page returns presentation label keys'
    );

    my $saved = $store->set_preferences(
        {
            preferences => [
                {
                    channel          => 'in_app',
                    digest_frequency => 'immediate',
                    enabled          => 1,
                },
                {
                    channel          => 'email',
                    digest_frequency => 'weekly',
                    enabled          => 0,
                },
                {
                    channel          => 'digest',
                    digest_frequency => 'weekly',
                    enabled          => 1,
                },
            ],
            user_id => $reader,
        }
    );
    is( $saved->[1]{enabled},
        0, 'bulk preference save persists disabled email' );
    is( $saved->[2]{digest_frequency},
        'weekly', 'bulk preference save persists digest frequency' );
    is_deeply(
        [ $store->enabled_channels($reader) ],
        [ 'in_app', 'digest' ],
        'a channel turned off leaves the enabled channels'
    );

    return;
}

# Another writer commits the same preference, an hour earlier, between the
# store's lookup and its insert.
sub _preference_race {
    my ($ctx) = @_;

    my $racer = $ctx->{users}{racer};
    my ( $raced, $updates ) = _sent(
        $ctx, 'UPDATE',
        'notification_preferences',
        sub {
            return _racing(
                $ctx,
                sub {
                    return
                      shift->do( $PREFERENCE_SQL, undef, $racer, 'email', 1,
                        'daily', $EARLIER );
                },
                sub {
                    return $ctx->{preferences}->set_preference(
                        {
                            channel          => 'email',
                            digest_frequency => 'daily',
                            enabled          => 1,
                            user_id          => $racer,
                        }
                    );
                }
            );
        }
    );
    ok( $raced->{skipped}, 'unique preference race skips the existing row' );
    is( _utc( $ctx, $raced->{updated_at} ),
        $EARLIER, 'unique preference race keeps the original timestamp' );
    is( _value( $ctx, $PREFERENCE_ROWS_SQL, $racer ),
        1, 'unique preference race does not insert another row' );
    is( scalar @{$updates},
        0, 'unique preference race does not update the row' );

    return;
}

sub _delivery {
    my ($ctx) = @_;

    my $reader     = $ctx->{users}{reader};
    my $hub        = GPForum::Service::Realtime::Hub->new;
    my $connection = GPForum::Test::RealtimeConnection->new;
    $hub->register_connection( 'notification-connection',
        { user_id => $reader }, $connection );
    $hub->subscribe(
        {
            actor         => { user_id => $reader },
            channel       => "notifications:$reader",
            connection_id => 'notification-connection',
        }
    );
    $ctx->{connection} = $connection;

    # Wired as Bootstrap wires it: ADR 0102's recipient policy both decides
    # who is notified and filters what the inbox shows.
    $ctx->{dispatcher} = GPForum::Service::Notification::Dispatcher->new(
        clock             => $ctx->{clock},
        permission_engine => $ctx->{policy},
        readability       => $ctx->{policy},
        realtime_notifier =>
          GPForum::Test::BadgeBroadcastSpy->new( hub => $hub ),
        schema             => $ctx->{schema},
        subscription_store => $ctx->{subscriptions},
    );
    my $post     = _post( $ctx, $ctx->{thread_id} );
    my %delivery = (
        notification_type => 'reply',
        payload           => { thread_id => $ctx->{thread_id} },
        recipient_user_id => $reader,
        source_id         => $post,
        source_type       => 'post',
    );
    my $created = $ctx->{dispatcher}->create_notification( {%delivery} );
    $ctx->{created} = $created;

    ok( $created->{ok}, 'notification is created' );
    my $id = $created->{notification}{notification_id};
    ok(
        GPForum::Infrastructure::Id->is_uuid($id),
        'notification id is deterministic UUID-shaped'
    );
    is( $created->{notification}{recipient_user_id},
        $reader, 'notification stores recipient' );
    is( $created->{notification}{source_type},
        'post', 'notification stores source type' );
    is( $created->{notification}{source_id},
        $post, 'notification stores source id' );
    is( $created->{notification}{notification_type},
        'reply', 'notification stores type' );
    is( $created->{notification}{payload}{thread_id},
        $ctx->{thread_id}, 'notification stores payload' );
    ok( $created->{idempotency_key},
        'notification delivery exposes idempotency key' );
    is( _value( $ctx, $NOTIFICATION_ROWS_SQL, $reader ),
        1, 'notification row is inserted' );
    is( _value( $ctx, $INBOX_ROWS_SQL, $reader ),
        1, 'inbox projection row is inserted' );
    is( _row( $ctx, $INBOX_ROW_SQL, $reader, $id )->{rank_score},
        0, 'inbox uses default rank' );
    is( $created->{unread_count},
        1, 'notification create reports unread count' );
    is( $connection->sent->[0]{json}{type},
        'notification.badge', 'notification create broadcasts badge update' );
    is( $connection->sent->[0]{json}{payload}{unread_count},
        1, 'notification create badge includes unread count' );

    my $duplicate = $ctx->{dispatcher}->create_notification( {%delivery} );
    ok( $duplicate->{ok},        'duplicate delivery succeeds' );
    ok( $duplicate->{duplicate}, 'duplicate delivery is identified' );
    is( $duplicate->{notification}{notification_id},
        $id, 'the same delivery derives the same id' );
    is( _value( $ctx, $NOTIFICATION_ROWS_SQL, $reader ),
        1, 'duplicate delivery does not insert notification row' );
    is( _value( $ctx, $INBOX_ROWS_SQL, $reader ),
        1, 'duplicate delivery does not insert inbox row' );

    return;
}

# Another worker commits the same delivery between the dispatcher's lookup
# of the inbox row and its inserts.
sub _raced_delivery {
    my ($ctx) = @_;

    my $member = $ctx->{users}{raced};
    my $id     = $ctx->{ids}->uuid;
    my $post   = _post( $ctx, $ctx->{thread_id} );
    my $raced  = _racing(
        $ctx,
        sub {
            my ($peer) = @_;
            $peer->do( $NOTIFICATION_SQL, undef, $id, $member, $post, $NOW );
            return $peer->do( $INBOX_SQL, undef, $member, $id, $NOW );
        },
        sub {
            return $ctx->{dispatcher}->create_notification(
                {
                    notification_id   => $id,
                    notification_type => 'reply',
                    recipient_user_id => $member,
                    source_id         => $post,
                    source_type       => 'post',
                }
            );
        }
    );
    ok( $raced->{ok}, 'unique notification race succeeds' );
    ok( $raced->{duplicate},
        'unique notification race is identified as duplicate' );
    is( _value( $ctx, $NOTIFICATION_ROWS_SQL, $member ),
        1, 'unique notification race does not insert a second notification' );
    is( _value( $ctx, $INBOX_ROWS_SQL, $member ),
        1, 'unique notification race does not insert a second inbox row' );

    return;
}

# The notification row is there and its inbox row is not: the delivery
# completes, writing the inbox row. The dispatcher accepts a conflict on the
# notification itself by its constraint, notifications_pkey; PostgreSQL
# names the index of the partition the row is stored in instead
# (notifications_default_pkey, notifications_2026_10_pkey), and matched on
# that name alone the conflict was rethrown and the delivery died where it
# should complete. The fake ORM raised the name the dispatcher looked for.
sub _leftover_notification {
    my ($ctx) = @_;

    _leftover_in( $ctx, $NOW,           'the default partition' );
    _leftover_in( $ctx, $IN_THIS_MONTH, 'a monthly partition' );

    return;
}

sub _leftover_in {
    my ( $ctx, $time, $partition ) = @_;

    my $member = $ctx->{users}{orphan};
    my $id     = $ctx->{ids}->uuid;
    my $post   = _post( $ctx, $ctx->{thread_id} );
    my $inbox  = _value( $ctx, $INBOX_ROWS_SQL, $member );
    $ctx->{dbh}->do( $NOTIFICATION_SQL, undef, $id, $member, $post, $time );
    my ( $orphan, $error );
    try {
        $orphan = _at(
            $ctx, $time,
            sub {
                return $ctx->{dispatcher}->create_notification(
                    {
                        notification_id   => $id,
                        notification_type => 'reply',
                        payload           => { thread_id => $ctx->{thread_id} },
                        recipient_user_id => $member,
                        source_id         => $post,
                        source_type       => 'post',
                    }
                );
            }
        );
    }
    catch ($caught) {
        $error = $caught;
    };

    ok( $orphan && $orphan->{ok},
        "a leftover notification in $partition completes its delivery" )
      or note $error;
    ok(
        $orphan && !$orphan->{duplicate},
        "a leftover notification in $partition is not taken for a duplicate"
          . ' delivery'
    );
    is( $orphan && $orphan->{notification}{notification_id},
        $id, "a leftover notification in $partition keeps its id" );
    is( _value( $ctx, $INBOX_ROWS_SQL, $member ),
        $inbox + 1,
        "a leftover notification in $partition gets its missing inbox row" );
    is( _value( $ctx, $NOTIFICATION_ID_ROWS_SQL, $id ),
        1, "a leftover notification in $partition is not inserted again" );

    return;
}

# A leftover notification stored at another time than the delivery's clock
# reads. notifications_pkey is (notification_id, created_at), so the insert
# did not conflict: a second notifications row with the same id was written
# beside the leftover, and the new inbox row, joined on both columns, reached
# only the second. ADR 0116: the dispatcher looks the id up in every
# partition and gives the inbox row the leftover's time.
sub _leftover_at_another_time {
    my ($ctx) = @_;

    _leftover_from( $ctx, $EARLIER, 'an earlier hour, in the same partition' );
    _leftover_from( $ctx, $IN_THIS_MONTH, q{another month's partition} );

    return;
}

sub _leftover_from {
    my ( $ctx, $time, $when ) = @_;

    my $member = $ctx->{users}{orphan};
    my $id     = $ctx->{ids}->uuid;
    my $post   = _post( $ctx, $ctx->{thread_id} );
    $ctx->{dbh}->do( $NOTIFICATION_SQL, undef, $id, $member, $post, $time );
    my ( $orphan, $error );
    try {
        $orphan = _at(
            $ctx, $NOW,
            sub {
                return $ctx->{dispatcher}->create_notification(
                    {
                        notification_id   => $id,
                        notification_type => 'reply',
                        payload           => { thread_id => $ctx->{thread_id} },
                        recipient_user_id => $member,
                        source_id         => $post,
                        source_type       => 'post',
                    }
                );
            }
        );
    }
    catch ($caught) {
        $error = $caught;
    };

    ok( $orphan && $orphan->{ok},
        "a leftover notification from $when completes its delivery" )
      or note $error;
    ok( $orphan && !$orphan->{duplicate},
        "a leftover notification from $when is no duplicate delivery" );
    is( _value( $ctx, $NOTIFICATION_ID_ROWS_SQL, $id ),
        1, "a leftover notification from $when is not inserted again" );
    is(
        _utc( $ctx, _row( $ctx, $INBOX_ROW_SQL, $member, $id )->{created_at} ),
        $time,
        "a leftover notification from $when gives its inbox row its time"
    );
    is( _value( $ctx, $INBOX_NOTIFICATION_SQL, $member, $id ),
        1, "the inbox row of a leftover from $when reaches the notification" );
    is( $orphan && _utc( $ctx, $orphan->{notification}{created_at} ),
        $time, "a leftover notification from $when is answered with its time" );

    return;
}

# Another worker commits the same delivery, at another time than the
# dispatcher's clock, after the dispatcher looked for the notification and
# before its inserts. Its notification insert does not conflict, but its
# inbox row does -- notification_inbox_pkey is the recipient and the id,
# whatever the time -- and the savepoint takes both back: ADR 0116's lookup
# needs no lock.
sub _raced_delivery_at_another_time {
    my ($ctx) = @_;

    my $member = $ctx->{users}{racer};
    my $id     = $ctx->{ids}->uuid;
    my $post   = _post( $ctx, $ctx->{thread_id} );
    my $inbox  = _value( $ctx, $INBOX_ROWS_SQL, $member );
    my $raced  = _at(
        $ctx, $NOW,
        sub {
            return _racing(
                $ctx,
                sub {
                    my ($peer) = @_;
                    $peer->do( $NOTIFICATION_SQL,
                        undef, $id, $member, $post, $EARLIER );
                    return $peer->do( $INBOX_SQL, undef, $member, $id,
                        $EARLIER );
                },
                sub {
                    return $ctx->{dispatcher}->create_notification(
                        {
                            notification_id   => $id,
                            notification_type => 'reply',
                            recipient_user_id => $member,
                            source_id         => $post,
                            source_type       => 'post',
                        }
                    );
                }
            );
        }
    );

    ok( $raced->{duplicate},
        'a delivery raced at another time is identified as duplicate' );
    is( _value( $ctx, $NOTIFICATION_ID_ROWS_SQL, $id ),
        1, 'a delivery raced at another time leaves one notification row' );
    is( _value( $ctx, $INBOX_ROWS_SQL, $member ),
        $inbox + 1, 'and one inbox row' );

    return;
}

sub _refused_delivery {
    my ($ctx) = @_;

    my $denied = $ctx->{dispatcher}->create_notification(
        {
            notification_type => 'reply',
            recipient_user_id => $ctx->{users}{reader},
            source_id         => $ctx->{staff_post},
            source_type       => 'post',
        }
    );
    ok( !$denied->{ok}, 'permission denied notification is skipped' );
    is( $denied->{skipped}, 'permission_denied',
        'permission denied reason is explicit' );
    is( _value( $ctx, $SOURCE_ROWS_SQL, $ctx->{staff_post} ),
        0, 'a source the recipient cannot read writes nothing' );

    my $muted = $ctx->{users}{muted};
    $ctx->{preferences}->set_preference(
        {
            channel          => 'in_app',
            digest_frequency => 'never',
            enabled          => 0,
            user_id          => $muted,
        }
    );
    ok(
        !$ctx->{preferences}->channel_enabled( $muted, 'in_app' ),
        'preference store reports disabled in-app channel'
    );
    my $muted_dispatcher = GPForum::Service::Notification::Dispatcher->new(
        clock            => $ctx->{clock},
        preference_store => $ctx->{preferences},
        schema           => $ctx->{schema},
    );
    my $skipped = $muted_dispatcher->create_notification(
        {
            notification_type => 'reply',
            recipient_user_id => $muted,
            source_id         => _post( $ctx, $ctx->{thread_id} ),
            source_type       => 'post',
        }
    );
    ok( !$skipped->{ok},
        'disabled in-app channel skips notification delivery' );
    is( $skipped->{skipped}, 'channel_disabled',
        'disabled notification channel reason is explicit' );
    is( _value( $ctx, $NOTIFICATION_ROWS_SQL, $muted ),
        0, 'disabled in-app channel does not insert notification row' );

    return;
}

sub _fanout {
    my ($ctx) = @_;

    my $reader = $ctx->{users}{reader};
    my %fanout = (
        notification_type => 'reply',
        payload           => { thread_id => $ctx->{thread_id} },
        source_id         => _post( $ctx, $ctx->{thread_id} ),
        source_type       => 'post',
        target_id         => $ctx->{thread_id},
        target_type       => 'thread',
    );
    my $fanned = $ctx->{dispatcher}->fanout_to_subscribers( {%fanout} );
    ok( $fanned->{ok}, 'fanout succeeds' );
    is( $fanned->{attempted},           1, 'fanout attempts subscribed users' );
    is( scalar @{ $fanned->{created} }, 1, 'fanout creates notifications' );
    is( _value( $ctx, $NOTIFICATION_ROWS_SQL, $reader ),
        2, 'fanout inserts another notification row' );
    is( $ctx->{dispatcher}->unread_count_for_user($reader),
        2, 'unread count includes direct and fanout notifications' );
    is( _badge($ctx), 2, 'fanout broadcasts updated unread badge' );

    my $again = $ctx->{dispatcher}->fanout_to_subscribers( {%fanout} );
    ok( $again->{ok}, 'duplicate fanout succeeds' );
    is( scalar @{ $again->{created} },
        0, 'duplicate fanout creates no new notification' );
    is( scalar @{ $again->{duplicates} },
        1, 'duplicate fanout reports duplicate delivery' );
    is( _value( $ctx, $NOTIFICATION_ROWS_SQL, $reader ),
        2, 'duplicate fanout does not add rows' );

    my $excluded = $ctx->{dispatcher}->fanout_to_subscribers(
        {
            %fanout,
            excluded_recipient_user_id => $reader,
            source_id                  => _post( $ctx, $ctx->{thread_id} ),
        }
    );
    ok( $excluded->{ok}, 'fanout with excluded actor succeeds' );
    is( $excluded->{attempted}, 0, 'fanout excludes the actor from attempts' );
    is( scalar @{ $excluded->{created} },
        0, 'fanout does not notify excluded actor' );

    return;
}

# A post.created event in outbox_messages, claimed and dispatched by the
# outbox, reaches the thread's subscribers; dispatched again, as a retry
# is, it adds nothing.
sub _outbox_fanout {
    my ($ctx) = @_;

    my $reader    = $ctx->{users}{reader};
    my $outbox_id = $ctx->{ids}->uuid;
    my $event_id  = $ctx->{ids}->uuid;
    $ctx->{dbh}->do(
        $OUTBOX_SQL,
        undef,
        $outbox_id,
        $event_id,
        "notification-test:$event_id",
        encode_json(
            {
                actor_id       => $ctx->{users}{author},
                aggregate_id   => _post( $ctx, $ctx->{thread_id} ),
                aggregate_type => 'post',
                domain_payload => { thread_id => $ctx->{thread_id} },
                event_id       => $event_id,
                event_type     => 'post.created',
            }
        )
    );
    my $outbox = GPForum::Service::Outbox::Dispatcher->new(
        schema    => $ctx->{schema},
        transport => GPForum::Service::Outbox::DomainEventTransport->new(
            handlers => [
                GPForum::Worker::Handler::NotificationDispatch->new(
                    dispatcher => $ctx->{dispatcher}
                ),
            ],
        ),
    );

    my $delivered = $outbox->dispatch_pending($OUTBOX_BATCH);
    is( $delivered->{dispatched}, 1, 'outbox event dispatch succeeds' );
    is( _value( $ctx, $OUTBOX_STATUS_SQL, $outbox_id ),
        'done', 'and the message is done' );
    is( _value( $ctx, $NOTIFICATION_ROWS_SQL, $reader ),
        $LISTED, 'outbox event fanout persists notification' );
    is( $ctx->{dispatcher}->unread_count_for_user($reader),
        $LISTED, 'outbox event fanout updates unread count' );
    is( _badge($ctx), $LISTED, 'outbox event fanout pushes badge update' );

    $ctx->{dbh}->do( $OUTBOX_RETRY_SQL, undef, $outbox_id );
    my $retried = $outbox->dispatch_pending($OUTBOX_BATCH);
    is( $retried->{dispatched}, 1, 'duplicate outbox event dispatch succeeds' );
    is( _value( $ctx, $NOTIFICATION_ROWS_SQL, $reader ),
        $LISTED, 'duplicate outbox event does not add rows' );

    return;
}

# PostgreSQL refuses the notification row: the recipient is reported as
# failed, and the fan-out still answers.
sub _degraded_fanout {
    my ($ctx) = @_;

    my $refused = _post( $ctx, $ctx->{thread_id} );
    $ctx->{dbh}->do( sprintf $REFUSE_SOURCE_SQL, $ctx->{dbh}->quote($refused) );
    my $degraded = GPForum::Service::Notification::Dispatcher->new(
        clock              => $ctx->{clock},
        schema             => $ctx->{schema},
        subscription_store => $ctx->{subscriptions},
    );
    my $fanned = $degraded->fanout_to_subscribers(
        {
            notification_type => 'reply',
            source_id         => $refused,
            source_type       => 'post',
            target_id         => $ctx->{thread_id},
            target_type       => 'thread',
        }
    );
    ok( $fanned->{ok},
        'notification fanout remains non-authoritative on dispatcher failure' );
    is( $fanned->{attempted}, 1,
        'degraded fanout still records attempted recipient' );
    is( scalar @{ $fanned->{created} },
        0, 'degraded fanout does not report failed notification as created' );
    is( scalar @{ $fanned->{failed} },
        1, 'degraded fanout records failed notification delivery' );

    return;
}

sub _inbox_listing {
    my ($ctx) = @_;

    my $reader = $ctx->{users}{reader};
    my $listed = $ctx->{dispatcher}->list_for_user( $reader, $LIST_LIMIT );
    is( scalar @{$listed}, $LISTED, 'notification inbox can be listed' );

    # Unqualified, recipient_user_id is ambiguous with the prefetched
    # notification's, and PostgreSQL refuses the statement.
    is_deeply(
        [ _unique( map { $_->get_column('recipient_user_id') } @{$listed} ) ],
        [$reader],
        'notification list filters recipient, qualified against the prefetch'
    );
    is( scalar @{ $ctx->{dispatcher}->list_for_user( $reader, 2 ) },
        2, 'notification list applies limit' );

    my ( undef, $selects ) = _sent(
        $ctx, 'SELECT', undef,
        sub {
            return [ map { $_->notification->get_column('payload') }
                  @{$listed} ];
        }
    );
    is( scalar @{$selects}, 0, 'notification list prefetches payload row' );

    return;
}

# Every delivery so far shares the fixed clock's created_at, so the pages
# turn on the keyset's tie-break: notification_id, descending.
sub _inbox_pages {
    my ($ctx) = @_;

    my $reader     = $ctx->{users}{reader};
    my $dispatcher = $ctx->{dispatcher};
    my $page =
      $dispatcher->list_page_for_user( $reader, { limit => $LIST_LIMIT } );
    is( scalar @{ $page->{items} },
        $LISTED, 'notification page returns inbox rows' );
    is( $page->{next_cursor}, undef,
        'notification page omits cursor when complete' );

    my $first = $dispatcher->list_page_for_user( $reader, { limit => 2 } );
    is( scalar @{ $first->{items} }, 2, 'a notification page holds its limit' );
    ok( $first->{has_next} && $first->{next_cursor},
        'notification page fetches one extra row to know another follows' );

    is_deeply(
        _walk(
            sub {
                return $dispatcher->list_page_for_user( $reader,
                    { after => shift, limit => 1 } );
            }
        ),
        $ctx->{dbh}->selectcol_arrayref( $INBOX_ORDER_SQL, undef, $reader ),
        'the pages walk every notification once, newest first, ties by id'
    );

    # The OR of the keyset plus the bound it implies on created_at, which
    # the index can start from. Without the bound a deep page read every
    # row before it.
    my ($sql) = @{
        ${
            $dispatcher->inbox_resultset(
                $reader,
                {
                    after => {
                        id => $ctx->{created}{notification}{notification_id},
                        sort_value => $NOW,
                    },
                    limit => $LIST_LIMIT,
                }
            )->as_query
        }
    };
    like(
        $sql,
        qr/me[.]created_at [ ] <= [ ] [?]/msx,
        'a notification page bounds created_at at its cursor'
    );
    ok( index( $sql, 'me.created_at = ? AND me.notification_id < ?' ) >= 0,
        'and applies the keyset predicate past it' );

    return;
}

sub _mark_read {
    my ($ctx) = @_;

    my $reader     = $ctx->{users}{reader};
    my $dispatcher = $ctx->{dispatcher};
    my $id         = $ctx->{created}{notification}{notification_id};
    my $read       = $dispatcher->mark_read( $id, $reader );
    is( $read->{notification_id},   $id, 'read state records notification' );
    is( $read->{recipient_user_id}, $reader, 'read state records recipient' );
    is( $read->{read_at},           $NOW,    'read state records timestamp' );
    is( _value( $ctx, $READ_ROWS_SQL, $reader ), 1, 'read row is upserted' );
    is( _utc( $ctx, _row( $ctx, $INBOX_ROW_SQL, $reader, $id )->{read_at} ),
        $NOW, 'inbox read projection is updated' );
    is( $read->{unread_count}, 2, 'mark read returns updated unread count' );
    is( _badge($ctx),          2, 'mark read broadcasts updated unread badge' );

    my $again =
      _at( $ctx, $LATER,
        sub { return $dispatcher->mark_read( $id, $reader ) } );
    ok( $again->{duplicate}, 'duplicate mark-read is idempotent' );
    is( _utc( $ctx, $again->{read_at} ),
        $NOW, 'duplicate mark-read answers with the first read time' );
    is( _value( $ctx, $READ_ROWS_SQL, $reader ),
        1, 'duplicate mark-read does not insert another read row' );

    # The read row is stored and the inbox not yet stamped: the read row's
    # time is the one kept.
    $ctx->{dbh}->do( $UNREAD_SQL, undef, $reader, $id );
    my $raced =
      _at( $ctx, $LATER,
        sub { return $dispatcher->mark_read( $id, $reader ) } );
    ok( $raced->{ok}, 'unique mark-read race succeeds' );
    is( _value( $ctx, $READ_ROWS_SQL, $reader ),
        1, 'unique mark-read race does not insert a second read row' );
    is( $raced->{unread_count},
        2, 'unique mark-read race keeps the unread count' );
    is( _utc( $ctx, _row( $ctx, $INBOX_ROW_SQL, $reader, $id )->{read_at} ),
        $NOW, 'unique mark-read race keeps the stored read timestamp' );

    my $missing = $dispatcher->mark_read( $ctx->{ids}->uuid, $reader );
    ok( !$missing->{ok}, 'missing notification read is rejected' );
    is( $missing->{error}, 'not_found',
        'missing notification read is explicit' );

    return;
}

sub _mark_all_read {
    my ($ctx) = @_;

    my $reader   = $ctx->{users}{reader};
    my $all_read = $ctx->{dispatcher}->mark_all_read($reader);
    ok( $all_read->{ok}, 'mark all read succeeds' );
    is( $all_read->{marked_count},
        2, 'mark all read updates remaining unread rows' );
    is( $all_read->{unread_count}, 0, 'mark all read clears the unread badge' );
    ok( !$all_read->{duplicate},
        'mark all read is not a duplicate when rows change' );
    is( _value( $ctx, $READ_ROWS_SQL, $reader ),
        $READ_ROWS, 'mark all read upserts remaining read rows' );
    is( _badge($ctx), 0, 'mark all read broadcasts a zero badge' );

    my $again = $ctx->{dispatcher}->mark_all_read($reader);
    ok( $again->{duplicate},
        'mark all read is idempotent when the inbox is already read' );
    is( $again->{marked_count}, 0, 'duplicate mark all read updates no rows' );
    is( _value( $ctx, $READ_ROWS_SQL, $reader ),
        $READ_ROWS, 'duplicate mark all read does not insert more read rows' );

    return;
}

# ADR 0102: a notification whose source the member can no longer read --
# here its category turned private -- leaves the inbox and the unread count,
# filtered before LIMIT so a page stays full, and mark-all-read leaves it
# unread rather than counting it. The two hidden ones are the newest: a
# page of two reads three rows to know another follows, so a filter applied
# after LIMIT would leave one row of the first page, where one hidden row
# would still have left it full.
sub _readable_inbox {
    my ($ctx) = @_;

    my $member     = $ctx->{users}{hidden};
    my $dispatcher = $ctx->{dispatcher};
    my %delivery   = (
        notification_type => 'reply',
        recipient_user_id => $member,
        source_type       => 'post',
    );
    for ( 1 .. $OPEN_SOURCES ) {
        $dispatcher->create_notification(
            { %delivery, source_id => _post( $ctx, $ctx->{thread_id} ) } );
    }
    my %hidden;
    for ( 1 .. $HIDDEN_SOURCES ) {
        my $club = _at(
            $ctx, $LATER,
            sub {
                return $dispatcher->create_notification(
                    {
                        %delivery,
                        source_id => _post( $ctx, $ctx->{club_thread} )
                    }
                );
            }
        );
        $hidden{ $club->{notification}{notification_id} } = 1;
    }
    is( $dispatcher->unread_count_for_user($member),
        $ALL_SOURCES,
        'every notification is counted while its source is readable' );

    $ctx->{dbh}->do( $CATEGORY_VISIBILITY_SQL, undef, 'private',
        $ctx->{categories}{club} );
    is( $dispatcher->unread_count_for_user($member), $OPEN_SOURCES,
        'a notification whose category turned private leaves the unread count'
    );
    my $first = $dispatcher->list_page_for_user( $member, { limit => 2 } );
    is( scalar @{ $first->{items} },
        2, 'and the inbox, filtered before LIMIT so the page stays full' );
    my $shown = _walk(
        sub {
            return $dispatcher->list_page_for_user( $member,
                { after => shift, limit => 2 } );
        }
    );
    is( scalar @{$shown}, $OPEN_SOURCES, 'the pages show the readable ones' );
    ok( !grep( { $hidden{$_} } @{$shown} ), 'and not the hidden ones' );

    my $all_read = $dispatcher->mark_all_read($member);
    is( $all_read->{marked_count},
        $OPEN_SOURCES, 'mark all read marks what the inbox shows' );
    is( $all_read->{unread_count}, 0, 'and the badge clears' );

    $ctx->{dbh}->do( $CATEGORY_VISIBILITY_SQL, undef, 'public',
        $ctx->{categories}{club} );
    is( $dispatcher->unread_count_for_user($member),
        $HIDDEN_SOURCES, 'the hidden notifications stayed unread' );

    return;
}

sub _unread_cap {
    my ($ctx) = @_;

    my $member = $ctx->{users}{backlog};
    my $post   = _post( $ctx, $ctx->{thread_id} );
    $ctx->{dbh}->do( $BACKLOG_SQL, undef, $member, $post, $NOW, $BACKLOG );
    $ctx->{dbh}->do( $BACKLOG_INBOX_SQL, undef, $member );

    is( $ctx->{dispatcher}->unread_count_for_user($member),
        $UNREAD_CAP, 'the unread count stops at its cap ("more than 99")' );
    my $delivered = $ctx->{dispatcher}->create_notification(
        {
            notification_type => 'reply',
            recipient_user_id => $member,
            source_id         => $post,
            source_type       => 'post',
        }
    );
    is( $delivered->{unread_count},
        $UNREAD_CAP, 'and a delivery reports the capped count' );

    return;
}

# A badge pushed from inside txn_do outlives a rollback the rows do not,
# leaving subscribers with an unread count that was never committed.
sub _badge_after_commit {
    my ($ctx) = @_;

    my $state = GPForum::Test::OpenTransaction->new( schema => $ctx->{schema} );
    ok( $ctx->{schema}->txn_do( sub { return $state->in_transaction } ),
        'the probe sees an open transaction' );
    my $spy        = GPForum::Test::BadgeBroadcastSpy->new( schema => $state );
    my $dispatcher = _spied_dispatcher( $ctx, $spy );
    my $member     = $ctx->{users}{badge};
    my $created    = $dispatcher->create_notification(
        {
            notification_type => 'reply',
            recipient_user_id => $member,
            source_id         => _post( $ctx, $ctx->{thread_id} ),
            source_type       => 'post',
        }
    );
    ok( $created->{ok}, 'committed delivery still succeeds' );
    is( $created->{unread_count},
        1, 'committed delivery still reports the unread count' );
    is( scalar @{ $spy->badges },
        1, 'committed delivery broadcasts exactly one badge' );
    is( $spy->badges->[0]{in_transaction},
        0, 'the delivery badge is broadcast after the transaction closed' );

    my $all_read = $dispatcher->mark_all_read($member);
    ok( $all_read->{ok}, 'mark all read still succeeds' );
    is( $all_read->{unread_count},
        0, 'mark all read still reports the cleared count' );
    is( $spy->badges->[-1]{in_transaction},
        0,
        'the mark-all-read badge is broadcast after its transaction closed' );

    # Every statement succeeds and PostgreSQL refuses the COMMIT.
    my $refused = $ctx->{users}{rollback};
    $ctx->{dbh}->do($REFUSE_COMMIT_FUNCTION_SQL);
    $ctx->{dbh}
      ->do( sprintf $REFUSE_COMMIT_TRIGGER_SQL, $ctx->{dbh}->quote($refused) );
    my $rollback_spy =
      GPForum::Test::BadgeBroadcastSpy->new( schema => $state );
    my $propagated = 0;
    try {

        # DBIx::Class warns that its rollback after the refused COMMIT had
        # nothing to roll back: PostgreSQL already had.
        local $SIG{__WARN__} = sub { return; };
        _spied_dispatcher( $ctx, $rollback_spy )->create_notification(
            {
                notification_type => 'reply',
                recipient_user_id => $refused,
                source_id         => _post( $ctx, $ctx->{thread_id} ),
                source_type       => 'post',
            }
        );
    }
    catch ($error) {
        $propagated = 1;
    };
    ok( $propagated, 'a failed commit propagates out of create_notification' );
    is( scalar @{ $rollback_spy->badges },
        0, 'no badge is broadcast when the delivery transaction rolls back' );
    is( _value( $ctx, $INBOX_ROWS_SQL, $refused ),
        0, 'and the delivery is not stored' );

    return;
}

sub _spied_dispatcher {
    my ( $ctx, $spy ) = @_;

    return GPForum::Service::Notification::Dispatcher->new(
        clock             => $ctx->{clock},
        permission_engine => $ctx->{policy},
        realtime_notifier => $spy,
        schema            => $ctx->{schema},
    );
}

# The badge is counted after the write committed. A count that failed was
# raised past the commit: a stored mark-read answered as a failure, and a
# fanout reported a recipient it had notified as failed.
#
# The count fails in PostgreSQL, as it does in production when a lock or the
# statement timeout cancels it: another session holds posts, which only the
# count's readability filter reads, past a short lock_timeout. The writes --
# the inbox, the reads, the notifications -- never wait on it.
sub _badge_count_failures {
    my ($ctx) = @_;

    my $log      = Mojo::Log->new( level => 'warn' );
    my $warnings = $log->capture('warn');
    my $spy      = GPForum::Test::BadgeBroadcastSpy->new( schema =>
          GPForum::Test::OpenTransaction->new( schema => $ctx->{schema} ) );
    my $dispatcher = GPForum::Service::Notification::Dispatcher->new(
        clock              => $ctx->{clock},
        logger             => $log,
        readability        => $ctx->{policy},
        realtime_notifier  => $spy,
        schema             => $ctx->{schema},
        stats              => { badge_failures => 0 },
        subscription_store => $ctx->{subscriptions},
    );
    my $member   = $ctx->{users}{counted};
    my %delivery = (
        notification_type => 'reply',
        payload           => { thread_id => $ctx->{thread_id} },
        recipient_user_id => $member,
        source_id         => _post( $ctx, $ctx->{thread_id} ),
        source_type       => 'post',
    );
    my $stored = $dispatcher->create_notification( {%delivery} );
    is( $stored->{unread_count},
        1, 'a delivery counts its badge while the count works' );

    my $id   = $stored->{notification}{notification_id};
    my $read = _counts_blocked( $ctx,
        sub { return $dispatcher->mark_read( $id, $member ) } );
    ok(
        $read && $read->{ok},
        'a mark-read whose badge count fails after the commit still answers ok'
    );
    ok( $read && !defined $read->{unread_count},
        'and reports no unread count rather than a wrong one' );
    is( _utc( $ctx, _row( $ctx, $INBOX_ROW_SQL, $member, $id )->{read_at} ),
        $NOW, 'the read is stored' );
    is( scalar @{ $spy->badges }, 1, 'no badge is sent without a count' );
    is( $dispatcher->snapshot->{badge_failures},
        1, 'the badge that could not be counted is counted as a failure' );
    my $not_sent  = qr/notification [ ] badge [ ] not [ ] sent:/msx;
    my $cancelled = qr/canceling [ ] statement/msx;
    like(
        "$warnings",
        qr/$not_sent [^\n]* $cancelled/msx,
        'and logged as a warning'
    );

    my $duplicate = _counts_blocked( $ctx,
        sub { return $dispatcher->create_notification( {%delivery} ) } );
    ok( $duplicate && $duplicate->{duplicate},
        'a duplicate delivery whose count fails still answers as a duplicate' );

    my $fanout_post = _post( $ctx, $ctx->{other_thread} );
    $ctx->{subscriptions}->subscribe(
        {
            preference  => 'all',
            target_id   => $ctx->{other_thread},
            target_type => 'thread',
            user_id     => $ctx->{users}{fanned},
        }
    );
    my $fanned = _counts_blocked(
        $ctx,
        sub {
            return $dispatcher->fanout_to_subscribers(
                {
                    notification_type => 'reply',
                    payload           => { thread_id => $ctx->{other_thread} },
                    source_id         => $fanout_post,
                    source_type       => 'post',
                    target_id         => $ctx->{other_thread},
                    target_type       => 'thread',
                }
            );
        }
    );
    is( scalar @{ $fanned->{created} },
        1,
        'a fanout whose badge count fails reports the recipient as notified' );
    is( scalar @{ $fanned->{failed} },
        0,
        'and not as failed, so the outbox does not retry a delivery it made' );
    is( $dispatcher->snapshot->{badge_failures},
        $UNCOUNTED_BADGES, 'every badge that could not be counted is counted' );

    return;
}

# $code's answer while the peer holds posts and this session gives up on a
# lock after a tenth of a second; undef, with the error noted, if it died.
sub _counts_blocked {
    my ( $ctx, $code ) = @_;

    my $dbh            = $ctx->{dbh};
    my $peer           = $ctx->{peer};
    my ($lock_timeout) = $dbh->selectrow_array('SHOW lock_timeout');
    $peer->begin_work;
    $peer->do($LOCK_POSTS_SQL);
    $dbh->do($SHORT_LOCK_TIMEOUT_SQL);
    my ( $answer, $error );
    try {
        $answer = $code->();
    }
    catch ($caught) {
        $error = $caught;
    };
    $peer->rollback;
    $dbh->do( 'SET lock_timeout = ' . $dbh->quote($lock_timeout) );

    if ($error) {
        note $error;
    }

    return $answer;
}

# A NOTIFY that fails keeps the count: the write and its count stand, and
# the next snapshot carries the badge. pg_notify refuses an empty channel.
sub _refused_notify {
    my ($ctx) = @_;

    my $dispatcher = GPForum::Service::Notification::Dispatcher->new(
        clock             => $ctx->{clock},
        permission_engine => $ctx->{policy},
        realtime_notifier => GPForum::Service::Realtime::PgNotifier->new(
            channel => q{},
            schema  => $ctx->{schema},
        ),
        schema => $ctx->{schema},
        stats  => { badge_failures => 0 },
    );
    my $delivered = $dispatcher->create_notification(
        {
            notification_type => 'reply',
            recipient_user_id => $ctx->{users}{unsent},
            source_id         => _post( $ctx, $ctx->{thread_id} ),
            source_type       => 'post',
        }
    );
    ok( $delivered->{ok}, 'a delivery whose NOTIFY fails succeeds' );
    is( $delivered->{unread_count}, 1, 'and keeps the unread count it read' );
    is( $dispatcher->snapshot->{badge_failures},
        1, 'the badge NOTIFY that failed is counted' );

    return;
}

# Runs $code with $competitor committing, on the peer connection, in the
# window between the store's lookup and its insert, where the store reads
# the clock. The store has to send its insert after the competing write, for
# PostgreSQL to refuse it: one that read the clock before its lookup would
# find the committed row instead, and pass here without meeting the conflict
# it is meant to handle.
sub _racing {
    my ( $ctx, $competitor, $code ) = @_;

    my $raced    = 0;
    my $inserted = 0;
    $ctx->{clock}->before_next_read(
        sub {
            $competitor->( $ctx->{peer} );
            $raced = 1;
            return;
        }
    );
    my ( $result, $error );
    try {
        $result = _tracing(
            $ctx,
            sub {
                my ($operation) = @_;
                if ( $raced && $operation eq 'INSERT' ) {
                    $inserted = 1;
                }
                return;
            },
            $code
        );
    }
    catch ($caught) {
        $error = $caught;
    };
    $ctx->{clock}->before_next_read(undef);
    croak $error                          if $error;
    croak 'the competing write never ran' if !$raced;
    croak 'the store found the competing row before trying its insert'
      if !$inserted;

    return $result;
}

# $code's answer with the clock at $time.
sub _at {
    my ( $ctx, $time, $code ) = @_;

    my $clock = $ctx->{clock};
    my $was   = $clock->iso8601;
    $clock->iso8601($time);
    my ( $result, $error );
    try {
        $result = $code->();
    }
    catch ($caught) {
        $error = $caught;
    };
    $clock->iso8601($was);
    croak $error if $error;

    return $result;
}

# $code's answer, and the statements of one verb (on $table, if given) it
# sent, as DBIx::Class traces them.
sub _sent {
    my ( $ctx, $verb, $table, $code ) = @_;

    my @sent;
    my $result = _tracing(
        $ctx,
        sub {
            my ( $operation, $statement ) = @_;
            return if $operation ne $verb;
            return
              if defined $table && $statement !~ /\b\Q$table\E\b/msx;
            push @sent, $statement;
            return;
        },
        $code
    );

    return ( $result, \@sent );
}

# $code's answer, with $trace told the verb and the text of every statement
# DBIx::Class sends meanwhile. A trace already listening keeps hearing them,
# so a race can run inside a count of statements.
sub _tracing {
    my ( $ctx, $trace, $code ) = @_;

    my $storage  = $ctx->{schema}->storage;
    my $previous = $storage->debugcb;
    my $debug    = $storage->debug;
    $storage->debugcb(
        sub {
            my ( $operation, $statement ) = @_;
            $trace->( $operation // q{}, $statement );
            if ($previous) {
                $previous->( $operation, $statement );
            }
            return;
        }
    );
    $storage->debug(1);
    my ( $result, $error );
    try {
        $result = $code->();
    }
    catch ($caught) {
        $error = $caught;
    };
    $storage->debug($debug);
    $storage->debugcb($previous);
    croak $error if $error;

    return $result;
}

# The badge count the reader's socket last received.
sub _badge {
    my ($ctx) = @_;

    return $ctx->{connection}->sent->[-1]{json}{payload}{unread_count};
}

# Every row of a keyset list, a page at a time.
sub _walk {
    my ($read) = @_;

    my $page  = $read->(undef);
    my @ids   = map { $_->get_column('notification_id') } @{ $page->{items} };
    my $pages = 1;
    while ( $page->{next_cursor} && $pages < $MAX_PAGES ) {
        $page = $read->( $page->{next_cursor} );
        push @ids,
          map { $_->get_column('notification_id') } @{ $page->{items} };
        $pages++;
    }

    return \@ids;
}

sub _unique {
    my (@values) = @_;

    my %seen;

    return grep { !$seen{$_}++ } @values;
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

1;
