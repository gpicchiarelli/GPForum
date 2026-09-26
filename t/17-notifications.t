# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;
use utf8;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Notification::Dispatcher;
use GPForum::Service::Notification::PreferenceStore;
use GPForum::Service::Notification::Renderer;
use GPForum::Service::Notification::SubscriptionStore;
use GPForum::Service::Outbox::DomainEventTransport;
use GPForum::Service::Realtime::Hub;
use GPForum::Test::BadgeBroadcastSpy;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::NotificationResultSet;
use GPForum::Test::NotificationSchema;
use GPForum::Test::NotificationTxnSchema;
use GPForum::Test::OutboxPayloadRow;
use GPForum::Test::PermissionEngine;
use GPForum::Test::RealtimeConnection;
use GPForum::Worker::Handler::NotificationDispatch;

our $VERSION = '0.001';

const my $LIST_LIMIT       => 10;
const my $MARKED_READ_ROWS => 3;

my $subscriptions = GPForum::Test::NotificationResultSet->new;
my $preferences   = GPForum::Test::NotificationResultSet->new;
my $notifications = GPForum::Test::NotificationResultSet->new;
my $reads         = GPForum::Test::NotificationResultSet->new;
my $inbox         = GPForum::Test::NotificationResultSet->new;
my $schema        = GPForum::Test::NotificationSchema->new(
    resultsets => {
        Subscription           => $subscriptions,
        NotificationPreference => $preferences,
        Notification           => $notifications,
        NotificationRead       => $reads,
        NotificationInbox      => $inbox,
    },
);
my $clock = GPForum::Test::FixedClock->new;

my $subscription_store = GPForum::Service::Notification::SubscriptionStore->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);
my $subscription = $subscription_store->subscribe(
    {
        user_id     => 'user-1',
        target_type => 'thread',
        target_id   => 'thread-1',
    }
);

is( $subscription->{subscription_id},
    'generated-1', 'subscription id is generated' );
is( $subscription->{user_id},     'user-1', 'subscription stores user' );
is( $subscription->{target_type}, 'thread', 'subscription stores target type' );
is( $subscription->{target_id},   'thread-1', 'subscription stores target id' );
is( $subscription->{preference},  'all', 'subscription defaults preference' );
is( $subscription->{created_at},
    '2026-05-23T12:00:00Z', 'subscription stores creation time' );
is( scalar @{ $subscriptions->created }, 1, 'subscription row is created' );

my $subscription_status =
  $subscription_store->status_for_user_target( 'user-1', 'thread', 'thread-1' );
is( $subscription_status->{subscribed}, 1, 'subscription status is active' );
is( $subscription_status->{muted}, 0, 'subscription status starts unmuted' );
is( $subscription_status->{subscription_id},
    'generated-1', 'subscription status exposes id' );

my $saved_subscription = $subscription_store->save_subscription(
    {
        user_id     => 'user-1',
        target_type => 'thread',
        target_id   => 'thread-1',
        preference  => 'mentions',
    }
);
is( $saved_subscription->{subscription_id},
    'generated-1', 'saving an existing subscription is idempotent' );
is( $saved_subscription->{preference},
    'mentions', 'idempotent subscription save updates preference' );
is( scalar @{ $subscriptions->created },
    1, 'idempotent subscription save does not insert a duplicate' );
my $held_subscription = $subscriptions->find('generated-1');
my $save_updates      = scalar @{ $held_subscription->updates };
my $saved_again       = $subscription_store->save_subscription(
    {
        user_id     => 'user-1',
        target_type => 'thread',
        target_id   => 'thread-1',
        preference  => 'mentions',
    }
);
ok( $saved_again->{skipped}, 'already-active subscription save is skipped' );
is( $saved_again->{preference},
    'mentions', 'already-active subscription keeps the preference' );
is( scalar @{ $held_subscription->updates },
    $save_updates, 'already-active subscription does not update the row' );

my $subscription_pk_rows = GPForum::Test::NotificationResultSet->new;
$subscription_pk_rows->create(
    {
        subscription_id => 'generated-1',
        target_id       => 'other-thread',
        target_type     => 'thread',
        user_id         => 'other-user',
    }
);
my $subscription_pk_store =
  GPForum::Service::Notification::SubscriptionStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::NotificationSchema->new(
        resultsets => { Subscription => $subscription_pk_rows },
    ),
  );
my $subscription_pk = $subscription_pk_store->save_subscription(
    {
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'user-1',
    }
);
ok( !$subscription_pk->{skipped},
    'unique subscription id collision remints and saves' );
is( $subscription_pk->{subscription_id},
    'generated-2', 'unique subscription id collision remints the id' );
is( $subscription_pk->{user_id},
    'user-1', 'unique subscription id collision keeps this user' );
is( $subscription_pk->{target_id},
    'thread-1', 'unique subscription id collision keeps this target' );

my $subscription_leftover_rows = GPForum::Test::NotificationResultSet->new;
$subscription_leftover_rows->create(
    {
        preference      => 'all',
        subscription_id => 'generated-1',
        target_id       => 'thread-1',
        target_type     => 'thread',
        user_id         => 'user-1',
    }
);
$subscription_leftover_rows->find_misses(1);
my $subscription_leftover_store =
  GPForum::Service::Notification::SubscriptionStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::NotificationSchema->new(
        resultsets => { Subscription => $subscription_leftover_rows },
    ),
  );
my $subscription_leftover = $subscription_leftover_store->save_subscription(
    {
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'user-1',
    }
);
ok( $subscription_leftover->{skipped},
    'leftover subscription id race reuses this subscription' );
is( $subscription_leftover->{subscription_id},
    'generated-1', 'leftover subscription id race keeps this subscription' );
is( $subscription_leftover->{user_id},
    'user-1', 'leftover subscription id race keeps this user' );
is( scalar @{ $subscription_leftover_rows->created },
    1, 'leftover subscription id race does not insert a second subscription' );

my $muted = $subscription_store->mute('generated-1');
is( $muted->{muted_at}, '2026-05-23T12:00:00Z', 'subscription can be muted' );
my $muted_row    = $subscriptions->find('generated-1');
my $mute_updates = scalar @{ $muted_row->updates };
my $muted_again  = $subscription_store->mute('generated-1');
ok( $muted_again->{skipped}, 'already-muted subscription is skipped' );
is( $muted_again->{muted_at},
    $muted->{muted_at},
    'already-muted subscription keeps the original timestamp' );
is( scalar @{ $muted_row->updates },
    $mute_updates, 'already-muted subscription does not update the row' );
my $revoked = $subscription_store->revoke('generated-1');
is( $revoked->{revoked_at},
    '2026-05-23T12:00:00Z', 'subscription can be revoked' );

my $revoked_status =
  $subscription_store->status_for_user_target( 'user-1', 'thread', 'thread-1' );
is( $revoked_status->{subscribed},
    0, 'revoked subscription status is inactive' );

my $restored_subscription = $subscription_store->save_subscription(
    {
        user_id     => 'user-1',
        target_type => 'thread',
        target_id   => 'thread-1',
        preference  => 'all',
    }
);
is( $restored_subscription->{subscription_id},
    'generated-1', 'save restores revoked subscription' );
is( $restored_subscription->{revoked_at},
    undef, 'restored subscription clears revocation' );

my $target_muted = $subscription_store->mute_for_user_target(
    {
        user_id     => 'user-1',
        target_type => 'thread',
        target_id   => 'thread-1',
    }
);
ok( $target_muted->{ok}, 'subscription can be muted by target' );
is( $target_muted->{muted_at},
    '2026-05-23T12:00:00Z', 'target mute records timestamp' );
my $target_mute_updates = scalar @{ $muted_row->updates };
my $target_muted_again  = $subscription_store->mute_for_user_target(
    {
        user_id     => 'user-1',
        target_type => 'thread',
        target_id   => 'thread-1',
    }
);
ok( $target_muted_again->{skipped},
    'already-muted target subscription is skipped' );
is(
    $target_muted_again->{muted_at},
    $target_muted->{muted_at},
    'already-muted target subscription keeps the original timestamp'
);
is( scalar @{ $muted_row->updates },
    $target_mute_updates,
    'already-muted target subscription does not update the row' );

my $unmuted_subscription = $subscription_store->save_subscription(
    {
        user_id     => 'user-1',
        target_type => 'thread',
        target_id   => 'thread-1',
        preference  => 'all',
    }
);
is( $unmuted_subscription->{preference},
    'all', 'save restores muted subscription preference' );
is( $unmuted_subscription->{muted_at}, undef, 'save clears muted state' );

my $target_revoked = $subscription_store->revoke_for_user_target(
    {
        user_id     => 'user-1',
        target_type => 'thread',
        target_id   => 'thread-1',
    }
);
ok( $target_revoked->{ok}, 'subscription can be revoked by target' );
is( $target_revoked->{revoked_at},
    '2026-05-23T12:00:00Z', 'target revoke records timestamp' );
my $target_revoke_updates = scalar @{ $muted_row->updates };
my $target_revoked_again  = $subscription_store->revoke_for_user_target(
    {
        user_id     => 'user-1',
        target_type => 'thread',
        target_id   => 'thread-1',
    }
);
ok( $target_revoked_again->{skipped},
    'already-revoked target subscription is skipped' );
is(
    $target_revoked_again->{revoked_at},
    $target_revoked->{revoked_at},
    'already-revoked target subscription keeps the original timestamp'
);
is( scalar @{ $muted_row->updates },
    $target_revoke_updates,
    'already-revoked target subscription does not update the row' );

my $active_subscription = $subscription_store->save_subscription(
    {
        user_id     => 'user-1',
        target_type => 'thread',
        target_id   => 'thread-1',
        preference  => 'all',
    }
);
is( $active_subscription->{muted_at}, undef, 'active restore clears mute' );
is( $active_subscription->{revoked_at},
    undef, 'active restore clears revocation' );

my $subscribers =
  [ $subscription_store->subscribers_for( 'thread', 'thread-1' ) ];
is_deeply( $subscribers, ['user-1'], 'subscribers can be listed' );

my $preference_store = GPForum::Service::Notification::PreferenceStore->new(
    schema => $schema,
    clock  => $clock,
);
my $preference = $preference_store->set_preference(
    {
        user_id          => 'user-1',
        channel          => 'email',
        enabled          => 1,
        digest_frequency => 'daily',
    }
);

is( $preference->{user_id}, 'user-1', 'preference stores user' );
is( $preference->{channel}, 'email',  'preference stores channel' );
is( $preference->{enabled}, 1,        'preference stores enabled flag' );
is( $preference->{digest_frequency},
    'daily', 'preference stores digest frequency' );
is( $preference->{updated_at},
    '2026-05-23T12:00:00Z', 'preference stores update time' );
is( scalar @{ $preferences->created }, 1, 'preference row is upserted' );
my $email_row =
  $preferences->find( { channel => 'email', user_id => 'user-1' } );
my $pref_updates    = scalar @{ $email_row->updates };
my $same_preference = $preference_store->set_preference(
    {
        user_id          => 'user-1',
        channel          => 'email',
        enabled          => 1,
        digest_frequency => 'daily',
    }
);
ok( $same_preference->{skipped},
    'already-applied notification preference is skipped' );
is(
    $same_preference->{updated_at},
    $preference->{updated_at},
    'already-applied notification preference keeps the original timestamp'
);
is( scalar @{ $email_row->updates },
    $pref_updates,
    'already-applied notification preference does not update the row' );

$preferences->find_misses(1);
my $raced_preference = $preference_store->set_preference(
    {
        user_id          => 'user-1',
        channel          => 'email',
        enabled          => 1,
        digest_frequency => 'daily',
    }
);
ok( $raced_preference->{skipped},
    'unique preference race skips the existing row' );
is(
    $raced_preference->{updated_at},
    $preference->{updated_at},
    'unique preference race keeps the original timestamp'
);
is( scalar @{ $preferences->created },
    1, 'unique preference race does not insert another row' );
is( scalar @{ $email_row->updates },
    $pref_updates, 'unique preference race does not update the row' );

is_deeply( [ $preference_store->enabled_channels('user-1') ],
    ['email'], 'enabled channels can be listed' );

my $preference_page = $preference_store->preferences_for_user('user-1');
is( scalar @{$preference_page},
    3, 'preference page exposes every supported channel' );
is( $preference_page->[0]{channel},
    'in_app', 'preference page has stable channel order' );
is( $preference_page->[1]{enabled},
    1, 'stored email preference overlays channel defaults' );
is( $preference_page->[2]{enabled}, 0, 'digest channel defaults to disabled' );
is(
    $preference_page->[0]{label_key},
    'notifications.channel.in_app',
    'preference page returns presentation label keys'
);

my $saved_preferences = $preference_store->set_preferences(
    {
        user_id     => 'user-1',
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
    }
);
is( $saved_preferences->[1]{enabled},
    0, 'bulk preference save persists disabled email' );
is( $saved_preferences->[2]{digest_frequency},
    'weekly', 'bulk preference save persists digest frequency' );

my $renderer           = GPForum::Service::Notification::Renderer->new;
my $reply_presentation = $renderer->render_inbox_item(
    'it',
    {
        notification_type => 'reply',
        source_type       => 'post',
        source_id         => 'post-1',
        payload           => { thread_id => 'thread-1', post_id => 'post-1' },
    }
);
is(
    $reply_presentation->{title},
    'Nuova risposta in una discussione seguita',
    'reply notification title is localized for inbox rendering'
);
is(
    $reply_presentation->{email}{subject},
    'Nuova risposta in una discussione seguita',
    'reply email subject uses the same localized notification template'
);

my $mention_presentation = $renderer->render_inbox_item(
    'en',
    {
        notification_type => 'mention',
        source_type       => 'post',
        source_id         => 'post-2',
        payload           => { thread_id => 'thread-1', post_id => 'post-2' },
    }
);
is(
    $mention_presentation->{title},
    'You were mentioned',
    'mention notification title is localized'
);
is(
    $mention_presentation->{email}{subject},
    'You were mentioned on GPForum',
    'mention email subject is localized'
);

my $follow_presentation = $renderer->render_inbox_item(
    'it',
    {
        notification_type => 'follow',
        source_type       => 'thread',
        source_id         => 'thread-1',
        payload           => { thread_id => 'thread-1' },
    }
);
is(
    $follow_presentation->{email}{subject},
    'Nuova attività in una discussione seguita',
    'follow email subject is localized'
);

my $fallback_presentation = $renderer->render_inbox_item(
    'zz',
    {
        notification_type => 'unknown',
        source_type       => 'post',
        source_id         => 'post-3',
        payload           => {},
    }
);
is( $fallback_presentation->{title},
    'Notification', 'unsupported locale and type use safe fallback text' );

my $rendered_mention = $renderer->render_mention(
    'it',
    {
        mention_id          => 'mention-1',
        source_type         => 'post',
        source_id           => 'post-1',
        actor_id            => 'user-2',
        actor_username      => 'reply_author',
        actor_profile_label => '@reply_author',
        actor_display_name  => 'Reply Author',
        mentioned_user_id   => 'user-1',
        mentioned_username  => 'giacomo',
    }
);
is( $rendered_mention->{by_label},
    'Menzione da', 'mention list label is localized' );
is(
    $rendered_mention->{email}{subject},
    '@reply_author ti ha menzionato su GPForum',
    'mention-specific email subject includes localized actor context'
);

my $realtime_hub        = GPForum::Service::Realtime::Hub->new;
my $realtime_connection = GPForum::Test::RealtimeConnection->new;
$realtime_hub->register_connection( 'notification-connection',
    { user_id => 'user-1' },
    $realtime_connection );
$realtime_hub->subscribe(
    {
        connection_id => 'notification-connection',
        actor         => { user_id => 'user-1' },
        channel       => 'notifications:user-1',
    }
);

my $dispatcher = GPForum::Service::Notification::Dispatcher->new(
    schema             => $schema,
    clock              => $clock,
    id_service         => GPForum::Test::Id->new,
    permission_engine  => GPForum::Test::PermissionEngine->new,
    realtime_hub       => $realtime_hub,
    subscription_store => $subscription_store,
);
my $created = $dispatcher->create_notification(
    {
        recipient_user_id => 'user-1',
        source_type       => 'post',
        source_id         => 'post-1',
        notification_type => 'reply',
        payload           => { thread_id => 'thread-1' },
    }
);

ok( $created->{ok}, 'notification is created' );
like(
    $created->{notification}{notification_id},
    qr/\A [[:xdigit:]-]+ \z/msx,
    'notification id is deterministic UUID-shaped'
);
is( $created->{notification}{recipient_user_id},
    'user-1', 'notification stores recipient' );
is( $created->{notification}{source_type},
    'post', 'notification stores source type' );
is( $created->{notification}{source_id},
    'post-1', 'notification stores source id' );
is( $created->{notification}{notification_type},
    'reply', 'notification stores type' );
is( $created->{notification}{payload}{thread_id},
    'thread-1', 'notification stores payload' );
ok( $created->{idempotency_key},
    'notification delivery exposes idempotency key' );
is( scalar @{ $notifications->created }, 1, 'notification row is inserted' );
is( scalar @{ $inbox->created },   1, 'inbox projection row is inserted' );
is( $created->{inbox}{rank_score}, 0, 'inbox uses default rank' );
is( $created->{unread_count}, 1, 'notification create reports unread count' );
is( $realtime_connection->sent->[0]{json}{type},
    'notification.badge', 'notification create broadcasts badge update' );
is( $realtime_connection->sent->[0]{json}{unread_count},
    1, 'notification create badge includes unread count' );

my $duplicate = $dispatcher->create_notification(
    {
        recipient_user_id => 'user-1',
        source_type       => 'post',
        source_id         => 'post-1',
        notification_type => 'reply',
        payload           => { thread_id => 'thread-1' },
    }
);
ok( $duplicate->{ok},        'duplicate delivery succeeds' );
ok( $duplicate->{duplicate}, 'duplicate delivery is identified' );
is( scalar @{ $notifications->created },
    1, 'duplicate delivery does not insert notification row' );
is( scalar @{ $inbox->created },
    1, 'duplicate delivery does not insert inbox row' );

$inbox->find_misses(1);
my $raced = $dispatcher->create_notification(
    {
        recipient_user_id => 'user-1',
        source_type       => 'post',
        source_id         => 'post-1',
        notification_type => 'reply',
        payload           => { thread_id => 'thread-1' },
    }
);
ok( $raced->{ok}, 'unique notification race succeeds' );
ok( $raced->{duplicate},
    'unique notification race is identified as duplicate' );
is( scalar @{ $notifications->created },
    1, 'unique notification race does not insert a second notification' );
is( scalar @{ $inbox->created },
    1, 'unique notification race does not insert a second inbox row' );

my $orphan_notifications = GPForum::Test::NotificationResultSet->new;
$orphan_notifications->create(
    {
        created_at        => '2026-05-23T12:00:00Z',
        notification_id   => 'notify-orphan-1',
        notification_type => 'reply',
        source_type       => 'post',
    }
);
my $orphan_inbox  = GPForum::Test::NotificationResultSet->new;
my $orphan_schema = GPForum::Test::NotificationSchema->new(
    resultsets => {
        Notification      => $orphan_notifications,
        NotificationInbox => $orphan_inbox,
        NotificationRead  => GPForum::Test::NotificationResultSet->new,
    },
);
my $orphan_dispatcher = GPForum::Service::Notification::Dispatcher->new(
    clock             => $clock,
    permission_engine => GPForum::Test::PermissionEngine->new,
    schema            => $orphan_schema,
);
my $orphan = $orphan_dispatcher->create_notification(
    {
        notification_id   => 'notify-orphan-1',
        notification_type => 'reply',
        payload           => { thread_id => 'thread-1' },
        recipient_user_id => 'user-1',
        source_id         => 'post-orphan',
        source_type       => 'post',
    }
);
ok( $orphan->{ok}, 'leftover notification race completes delivery' );
ok( !$orphan->{duplicate},
    'leftover notification race does not treat a missing inbox as duplicate' );
is( $orphan->{notification}{notification_id},
    'notify-orphan-1', 'leftover notification race keeps this notification' );
is( scalar @{ $orphan_notifications->created },
    1, 'leftover notification race does not insert a second notification' );
is( scalar @{ $orphan_inbox->created },
    1, 'leftover notification race inserts the missing inbox' );

my $denied_dispatcher = GPForum::Service::Notification::Dispatcher->new(
    schema            => $schema,
    clock             => $clock,
    id_service        => GPForum::Test::Id->new,
    permission_engine => GPForum::Test::PermissionEngine->new(
        denied => { 'user-denied' => 1 },
    ),
);
my $denied = $denied_dispatcher->create_notification(
    {
        recipient_user_id => 'user-denied',
        source_type       => 'post',
        source_id         => 'post-2',
        notification_type => 'reply',
    }
);

ok( !$denied->{ok}, 'permission denied notification is skipped' );
is( $denied->{skipped}, 'permission_denied',
    'permission denied reason is explicit' );

$preference_store->set_preference(
    {
        user_id          => 'user-muted',
        channel          => 'in_app',
        enabled          => 0,
        digest_frequency => 'never',
    }
);
ok(
    !$preference_store->channel_enabled( 'user-muted', 'in_app' ),
    'preference store reports disabled in-app channel'
);
my $muted_dispatcher = GPForum::Service::Notification::Dispatcher->new(
    schema           => $schema,
    clock            => $clock,
    preference_store => $preference_store,
);
my $muted_notification = $muted_dispatcher->create_notification(
    {
        recipient_user_id => 'user-muted',
        source_type       => 'post',
        source_id         => 'post-muted',
        notification_type => 'reply',
    }
);
ok( !$muted_notification->{ok},
    'disabled in-app channel skips notification delivery' );
is( $muted_notification->{skipped},
    'channel_disabled', 'disabled notification channel reason is explicit' );
is( scalar @{ $notifications->created },
    1, 'disabled in-app channel does not insert notification row' );

my $fanout = $dispatcher->fanout_to_subscribers(
    {
        target_type       => 'thread',
        target_id         => 'thread-1',
        source_type       => 'post',
        source_id         => 'post-3',
        notification_type => 'reply',
        payload           => { thread_id => 'thread-1' },
    }
);

ok( $fanout->{ok}, 'fanout succeeds' );
is( $fanout->{attempted},           1, 'fanout attempts subscribed users' );
is( scalar @{ $fanout->{created} }, 1, 'fanout creates notifications' );
is( scalar @{ $notifications->created },
    2, 'fanout inserts another notification row' );
is( $dispatcher->unread_count_for_user('user-1'),
    2, 'unread count includes direct and fanout notifications' );
is( $realtime_connection->sent->[-1]{json}{unread_count},
    2, 'fanout broadcasts updated unread badge' );

my $duplicate_fanout = $dispatcher->fanout_to_subscribers(
    {
        target_type       => 'thread',
        target_id         => 'thread-1',
        source_type       => 'post',
        source_id         => 'post-3',
        notification_type => 'reply',
        payload           => { thread_id => 'thread-1' },
    }
);
ok( $duplicate_fanout->{ok}, 'duplicate fanout succeeds' );
is( scalar @{ $duplicate_fanout->{created} },
    0, 'duplicate fanout creates no new notification' );
is( scalar @{ $duplicate_fanout->{duplicates} },
    1, 'duplicate fanout reports duplicate delivery' );
is( scalar @{ $notifications->created },
    2, 'duplicate fanout does not add rows' );

my $transport = GPForum::Service::Outbox::DomainEventTransport->new(
    handlers => [
        GPForum::Worker::Handler::NotificationDispatch->new(
            dispatcher => $dispatcher
        ),
    ],
);
my $outbox_message = GPForum::Test::OutboxPayloadRow->new(
    data => {
        payload => {
            event_id       => 'event-reply-1',
            event_type     => 'post.created',
            aggregate_type => 'post',
            aggregate_id   => 'post-5',
            actor_id       => 'user-author',
            domain_payload => { thread_id => 'thread-1' },
        },
    },
);
my $outbox_delivery = $transport->dispatch($outbox_message);
ok( $outbox_delivery->{ok}, 'outbox event dispatch succeeds' );
is( $outbox_delivery->{handlers},
    1, 'outbox event dispatches notification handler' );
is( scalar @{ $notifications->created },
    3, 'outbox event fanout persists notification' );
is( $dispatcher->unread_count_for_user('user-1'),
    3, 'outbox event fanout updates unread count' );
is( $realtime_connection->sent->[-1]{json}{unread_count},
    3, 'outbox event fanout pushes badge update' );

my $duplicate_outbox_delivery = $transport->dispatch($outbox_message);
ok( $duplicate_outbox_delivery->{ok},
    'duplicate outbox event dispatch succeeds' );
is( scalar @{ $notifications->created },
    3, 'duplicate outbox event does not add rows' );

my $failing_notifications =
  GPForum::Test::NotificationResultSet->new( fail_create => 1 );
my $failure_schema = GPForum::Test::NotificationSchema->new(
    resultsets => {
        Subscription           => $subscriptions,
        NotificationPreference => $preferences,
        Notification           => $failing_notifications,
        NotificationRead       => $reads,
        NotificationInbox      => $inbox,
    },
);
my $degraded_dispatcher = GPForum::Service::Notification::Dispatcher->new(
    schema             => $failure_schema,
    clock              => $clock,
    id_service         => GPForum::Test::Id->new,
    subscription_store => $subscription_store,
);
my $degraded_fanout = $degraded_dispatcher->fanout_to_subscribers(
    {
        target_type       => 'thread',
        target_id         => 'thread-1',
        source_type       => 'post',
        source_id         => 'post-failure',
        notification_type => 'reply',
    }
);
ok( $degraded_fanout->{ok},
    'notification fanout remains non-authoritative on dispatcher failure' );
is( $degraded_fanout->{attempted},
    1, 'degraded fanout still records attempted recipient' );
is( scalar @{ $degraded_fanout->{created} },
    0, 'degraded fanout does not report failed notification as created' );
is( scalar @{ $degraded_fanout->{failed} },
    1, 'degraded fanout records failed notification delivery' );

my $excluded_fanout = $dispatcher->fanout_to_subscribers(
    {
        target_type                => 'thread',
        target_id                  => 'thread-1',
        source_type                => 'post',
        source_id                  => 'post-4',
        notification_type          => 'reply',
        excluded_recipient_user_id => 'user-1',
        payload                    => { thread_id => 'thread-1' },
    }
);

ok( $excluded_fanout->{ok}, 'fanout with excluded actor succeeds' );
is( $excluded_fanout->{attempted},
    0, 'fanout excludes the actor from attempts' );
is( scalar @{ $excluded_fanout->{created} },
    0, 'fanout does not notify excluded actor' );

my $listed = $dispatcher->list_for_user( 'user-1', $LIST_LIMIT );

is( scalar @{$listed}, 3, 'notification inbox can be listed' );
is( $inbox->last_query->{'me.recipient_user_id'},
    'user-1', 'notification list filters recipient' );
ok( !exists $inbox->last_query->{recipient_user_id},
    'notification list qualifies recipient against prefetched notification' );
is( $inbox->last_attrs->{rows}, $LIST_LIMIT,
    'notification list applies limit' );
is( $inbox->last_attrs->{prefetch},
    'notification', 'notification list prefetches payload row' );

my $notification_page =
  $dispatcher->list_page_for_user( 'user-1', { limit => $LIST_LIMIT } );
is( scalar @{ $notification_page->{items} },
    3, 'notification page returns inbox rows' );
is( $notification_page->{next_cursor},
    undef, 'notification page omits cursor when complete' );
is(
    $inbox->last_attrs->{rows},
    $LIST_LIMIT + 1,
    'notification page fetches one extra row'
);

my $read =
  $dispatcher->mark_read( $created->{notification}{notification_id}, 'user-1' );

is(
    $read->{notification_id},
    $created->{notification}{notification_id},
    'read state records notification'
);
is( $read->{recipient_user_id}, 'user-1',     'read state records recipient' );
is( $read->{read_at}, '2026-05-23T12:00:00Z', 'read state records timestamp' );
is( scalar @{ $reads->created }, 1,           'read row is upserted' );
is(
    $inbox->find(
        {
            recipient_user_id => 'user-1',
            notification_id   => $created->{notification}{notification_id},
        }
    )->get_column('read_at'),
    '2026-05-23T12:00:00Z',
    'inbox read projection is updated'
);
is( $read->{unread_count}, 2, 'mark read returns updated unread count' );
is( $realtime_connection->sent->[-1]{json}{unread_count},
    2, 'mark read broadcasts updated unread badge' );

my $duplicate_read =
  $dispatcher->mark_read( $created->{notification}{notification_id}, 'user-1' );
ok( $duplicate_read->{duplicate}, 'duplicate mark-read is idempotent' );
is( scalar @{ $reads->created },
    1, 'duplicate mark-read does not insert another read row' );

$inbox->find(
    {
        recipient_user_id => 'user-1',
        notification_id   => $created->{notification}{notification_id},
    }
)->update( { read_at => undef } );
my $raced_read =
  $dispatcher->mark_read( $created->{notification}{notification_id}, 'user-1' );
ok( $raced_read->{ok}, 'unique mark-read race succeeds' );
is( scalar @{ $reads->created },
    1, 'unique mark-read race does not insert a second read row' );
is( $raced_read->{unread_count},
    2, 'unique mark-read race keeps the unread count' );
is(
    $inbox->find(
        {
            recipient_user_id => 'user-1',
            notification_id   => $created->{notification}{notification_id},
        }
    )->get_column('read_at'),
    '2026-05-23T12:00:00Z',
    'unique mark-read race keeps the stored read timestamp'
);

my $missing_read = $dispatcher->mark_read( 'missing', 'user-1' );
ok( !$missing_read->{ok}, 'missing notification read is rejected' );
is( $missing_read->{error},
    'not_found', 'missing notification read is explicit' );

my $all_read = $dispatcher->mark_all_read('user-1');
ok( $all_read->{ok}, 'mark all read succeeds' );
is( $all_read->{marked_count},
    2, 'mark all read updates remaining unread rows' );
is( $all_read->{unread_count}, 0, 'mark all read clears the unread badge' );
ok( !$all_read->{duplicate},
    'mark all read is not a duplicate when rows change' );
is( scalar @{ $reads->created },
    $MARKED_READ_ROWS, 'mark all read upserts remaining read rows' );
is( $realtime_connection->sent->[-1]{json}{unread_count},
    0, 'mark all read broadcasts a zero badge' );

my $duplicate_all = $dispatcher->mark_all_read('user-1');
ok( $duplicate_all->{duplicate},
    'mark all read is idempotent when the inbox is already read' );
is( $duplicate_all->{marked_count},
    0, 'duplicate mark all read updates no rows' );
is( scalar @{ $reads->created },
    $MARKED_READ_ROWS,
    'duplicate mark all read does not insert more read rows' );

# A badge pushed from inside txn_do outlives a rollback the rows do not,
# leaving subscribers with an unread count that was never committed.
my $badge_schema = GPForum::Test::NotificationTxnSchema->new(
    resultsets => {
        Notification      => GPForum::Test::NotificationResultSet->new,
        NotificationInbox => GPForum::Test::NotificationResultSet->new,
        NotificationRead  => GPForum::Test::NotificationResultSet->new,
    },
);
my $badge_spy =
  GPForum::Test::BadgeBroadcastSpy->new( schema => $badge_schema );
my $badge_dispatcher = GPForum::Service::Notification::Dispatcher->new(
    clock             => $clock,
    id_service        => GPForum::Test::Id->new,
    permission_engine => GPForum::Test::PermissionEngine->new,
    realtime_hub      => $badge_spy,
    schema            => $badge_schema,
);
my $badge_created = $badge_dispatcher->create_notification(
    {
        notification_type => 'reply',
        payload           => { thread_id => 'thread-9' },
        recipient_user_id => 'user-9',
        source_id         => 'post-9',
        source_type       => 'post',
    }
);

ok( $badge_created->{ok}, 'committed delivery still succeeds' );
is( $badge_created->{unread_count},
    1, 'committed delivery still reports the unread count' );
is( scalar @{ $badge_spy->badges },
    1, 'committed delivery broadcasts exactly one badge' );
is( $badge_spy->badges->[0]{in_transaction},
    0, 'the delivery badge is broadcast after the transaction closed' );

my $badge_all_read = $badge_dispatcher->mark_all_read('user-9');

ok( $badge_all_read->{ok}, 'mark all read still succeeds' );
is( $badge_all_read->{unread_count},
    0, 'mark all read still reports the cleared count' );
is( $badge_spy->badges->[-1]{in_transaction},
    0, 'the mark-all-read badge is broadcast after its transaction closed' );

my $rollback_schema = GPForum::Test::NotificationTxnSchema->new(
    commit_fails => 1,
    resultsets   => {
        Notification      => GPForum::Test::NotificationResultSet->new,
        NotificationInbox => GPForum::Test::NotificationResultSet->new,
        NotificationRead  => GPForum::Test::NotificationResultSet->new,
    },
);
my $rollback_spy =
  GPForum::Test::BadgeBroadcastSpy->new( schema => $rollback_schema );
my $rollback_dispatcher = GPForum::Service::Notification::Dispatcher->new(
    clock             => $clock,
    id_service        => GPForum::Test::Id->new,
    permission_engine => GPForum::Test::PermissionEngine->new,
    realtime_hub      => $rollback_spy,
    schema            => $rollback_schema,
);
my $rolled_back = eval {
    $rollback_dispatcher->create_notification(
        {
            notification_type => 'reply',
            payload           => { thread_id => 'thread-10' },
            recipient_user_id => 'user-10',
            source_id         => 'post-10',
            source_type       => 'post',
        }
    );
    return 1;
};

ok( !$rolled_back, 'a failed commit propagates out of create_notification' );
is( scalar @{ $rollback_spy->badges },
    0, 'no badge is broadcast when the delivery transaction rolls back' );

done_testing();

1;
