package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Notification::Dispatcher;
use GPForum::Service::Notification::PreferenceStore;
use GPForum::Service::Notification::SubscriptionStore;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::NotificationResultSet;
use GPForum::Test::NotificationSchema;
use GPForum::Test::PermissionEngine;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 41;
const my $LIST_LIMIT     => 10;

plan tests => $EXPECTED_TESTS;

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

my $muted = $subscription_store->mute('generated-1');
is( $muted->{muted_at}, '2026-05-23T12:00:00Z', 'subscription can be muted' );
my $revoked = $subscription_store->revoke('generated-1');
is( $revoked->{revoked_at},
    '2026-05-23T12:00:00Z', 'subscription can be revoked' );

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
is_deeply( [ $preference_store->enabled_channels('user-1') ],
    ['email'], 'enabled channels can be listed' );

my $dispatcher = GPForum::Service::Notification::Dispatcher->new(
    schema             => $schema,
    clock              => $clock,
    id_service         => GPForum::Test::Id->new,
    permission_engine  => GPForum::Test::PermissionEngine->new,
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
is( $created->{notification}{notification_id},
    'generated-1', 'notification id is generated' );
is( $created->{notification}{recipient_user_id},
    'user-1', 'notification stores recipient' );
is( $created->{notification}{source_type},
    'post', 'notification stores source type' );
is( $created->{notification}{source_id},
    'post-1', 'notification stores source id' );
is( $created->{notification}{notification_type},
    'reply', 'notification stores type' );
is_deeply(
    $created->{notification}{payload},
    { thread_id => 'thread-1' },
    'notification stores payload'
);
is( scalar @{ $notifications->created }, 1, 'notification row is inserted' );
is( scalar @{ $inbox->created },   1, 'inbox projection row is inserted' );
is( $created->{inbox}{rank_score}, 0, 'inbox uses default rank' );

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

my $listed = $dispatcher->list_for_user( 'user-1', $LIST_LIMIT );

is( scalar @{$listed}, 2, 'notification inbox can be listed' );
is( $inbox->last_query->{recipient_user_id},
    'user-1', 'notification list filters recipient' );
is( $inbox->last_attrs->{rows}, $LIST_LIMIT,
    'notification list applies limit' );

my $read = $dispatcher->mark_read( 'generated-1', 'user-1' );

is( $read->{notification_id}, 'generated-1',
    'read state records notification' );
is( $read->{recipient_user_id}, 'user-1',     'read state records recipient' );
is( $read->{read_at}, '2026-05-23T12:00:00Z', 'read state records timestamp' );
is( scalar @{ $reads->created }, 1,           'read row is upserted' );
is(
    $inbox->find(
        {
            recipient_user_id => 'user-1',
            notification_id   => 'generated-1',
        }
    )->get_column('read_at'),
    '2026-05-23T12:00:00Z',
    'inbox read projection is updated'
);

1;
