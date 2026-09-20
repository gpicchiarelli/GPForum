package main;

use strict;
use warnings;

use Const::Fast;
use MIME::Base64 qw(encode_base64url);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Community::BookmarkStore;
use GPForum::Service::Community::FeedReader;
use GPForum::Service::Community::FeedProjector;
use GPForum::Service::Community::MentionExtractor;
use GPForum::Service::Community::MentionReader;
use GPForum::Service::Community::MentionStore;
use GPForum::Service::Community::ReputationLedger;
use GPForum::Test::CommunityResultSet;
use GPForum::Test::CommunityRow;
use GPForum::Test::CommunitySchema;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::NotificationDispatcher;
use GPForum::Test::SearchResultSet;
use GPForum::Test::SearchRow;

our $VERSION = '0.001';

const my $EXPECTED_TESTS       => 157;
const my $BOOKMARK_LIMIT       => 20;
const my $MENTION_COUNT        => 2;
const my $DEFAULT_RANK         => 0;
const my $REPUTATION_DELTA     => 15;
const my $CURRENT_SCORE        => 40;
const my $EXPECTED_SCORE       => 55;
const my $FOLLOW_ON_SCORE      => 70;
const my $SNAPSHOT_SEED_SCORE  => 10;
const my $SNAPSHOT_RACE_SCORE  => 25;
const my $FOLLOW_ON_EVENTS     => 2;
const my $EXPECTED_TRUST_LEVEL => 2;
const my $FEED_USER_COUNT      => 2;
const my $DEFAULT_VERSION      => 1;
const my $AT_CODE              => 64;
const my $AT_SIGN              => chr $AT_CODE;
const my $MENTION_READER_LIMIT => 10;
const my $MENTION_FETCH_ROWS   => $MENTION_READER_LIMIT + 1;
const my $FEED_READER_LIMIT    => 10;
const my $FEED_FETCH_ROWS      => $FEED_READER_LIMIT + 1;

plan tests => $EXPECTED_TESTS;

my $extractor = GPForum::Service::Community::MentionExtractor->new;
my $mentions  = $extractor->extract(
    join q{},
    'Ciao ',
    $AT_SIGN,
    'Giacomo, grazie a ',
    $AT_SIGN,
    'alice e ancora ',
    $AT_SIGN,
    'giacomo. Email a',
    $AT_SIGN,
    'b.it no.'
);

is( scalar @{$mentions},      $MENTION_COUNT, 'mentions are unique' );
is( $mentions->[0]{username}, 'giacomo', 'mention usernames are normalized' );
is( $mentions->[0]{label}, $AT_SIGN . 'giacomo', 'mention label is explicit' );
is( $mentions->[1]{username}, 'alice',           'second mention is detected' );
is_deeply( $extractor->extract(undef), [], 'empty body has no mentions' );

my $bookmarks         = GPForum::Test::CommunityResultSet->new;
my $mentions_rows     = GPForum::Test::CommunityResultSet->new;
my $users             = GPForum::Test::CommunityResultSet->new;
my $reputation_events = GPForum::Test::CommunityResultSet->new;
my $trust_snapshots   = GPForum::Test::CommunityResultSet->new;
my $feed_items        = GPForum::Test::CommunityResultSet->new;
my $feed_posts        = GPForum::Test::SearchResultSet->new(
    rows => [
        GPForum::Test::SearchRow->new(
            data => {
                post_id   => 'post-1',
                thread_id => 'thread-1',
            },
        ),
    ],
);
my $schema = GPForum::Test::CommunitySchema->new(
    resultsets => {
        Bookmark           => $bookmarks,
        Mention            => $mentions_rows,
        Post               => $feed_posts,
        User               => $users,
        ReputationEvent    => $reputation_events,
        TrustScoreSnapshot => $trust_snapshots,
        UserFeedItem       => $feed_items,
    },
);
my $clock      = GPForum::Test::FixedClock->new;
my $id_service = GPForum::Test::Id->new;

my $bookmark_store = GPForum::Service::Community::BookmarkStore->new(
    schema     => $schema,
    clock      => $clock,
    id_service => $id_service,
);
my $bookmark = $bookmark_store->create_bookmark(
    {
        user_id     => 'user-1',
        target_type => 'thread',
        target_id   => 'thread-1',
        note        => 'rileggi',
    }
);

is( $bookmark->{bookmark_id}, 'generated-1', 'bookmark id is generated' );
is( $bookmark->{user_id},     'user-1',      'bookmark stores owner' );
is( $bookmark->{target_type}, 'thread',      'bookmark stores target type' );
is( $bookmark->{target_id},   'thread-1',    'bookmark stores target id' );
is( $bookmark->{note},        'rileggi',     'bookmark stores note' );
is( $bookmark->{created_at},
    '2026-05-23T12:00:00Z', 'bookmark stores creation time' );
is( scalar @{ $bookmarks->created }, 1, 'bookmark row is inserted' );

my $bookmark_status =
  $bookmark_store->status_for_user_target( 'user-1', 'thread', 'thread-1' );
is( $bookmark_status->{bookmarked}, 1, 'bookmark status is active' );
is( $bookmark_status->{bookmark_id},
    'generated-1', 'bookmark status exposes bookmark id' );

my $saved_bookmark = $bookmark_store->save_bookmark(
    {
        user_id     => 'user-1',
        target_type => 'thread',
        target_id   => 'thread-1',
        note        => 'aggiornato',
    }
);
is( $saved_bookmark->{bookmark_id},
    'generated-1', 'saving an existing bookmark is idempotent' );
is( $saved_bookmark->{note}, 'aggiornato', 'save updates bookmark note' );
is( scalar @{ $bookmarks->created },
    1, 'idempotent bookmark save does not insert a duplicate' );
my $active_bookmark = $bookmarks->find('generated-1');
my $save_updates    = scalar @{ $active_bookmark->updates };
my $saved_again     = $bookmark_store->save_bookmark(
    {
        user_id     => 'user-1',
        target_type => 'thread',
        target_id   => 'thread-1',
        note        => 'aggiornato',
    }
);
ok( $saved_again->{skipped}, 'already-active bookmark save is skipped' );
is( $saved_again->{note},
    'aggiornato', 'already-active bookmark keeps the note' );
is( scalar @{ $active_bookmark->updates },
    $save_updates, 'already-active bookmark does not update the row' );

my $bookmark_pk_rows = GPForum::Test::CommunityResultSet->new;
$bookmark_pk_rows->create(
    {
        bookmark_id => 'generated-1',
        target_id   => 'other-thread',
        target_type => 'thread',
        user_id     => 'other-user',
    }
);
my $bookmark_pk_store = GPForum::Service::Community::BookmarkStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::CommunitySchema->new(
        resultsets => { Bookmark => $bookmark_pk_rows },
    ),
);
my $bookmark_pk = $bookmark_pk_store->save_bookmark(
    {
        note        => 'rileggi',
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'user-1',
    }
);
ok( !$bookmark_pk->{skipped},
    'unique bookmark id collision remints and saves' );
is( $bookmark_pk->{bookmark_id},
    'generated-2', 'unique bookmark id collision remints the id' );
is( $bookmark_pk->{user_id},
    'user-1', 'unique bookmark id collision keeps this user' );
is( $bookmark_pk->{target_id},
    'thread-1', 'unique bookmark id collision keeps this target' );

my $bookmark_leftover_rows = GPForum::Test::CommunityResultSet->new;
$bookmark_leftover_rows->create(
    {
        bookmark_id => 'generated-1',
        note        => 'rileggi',
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'user-1',
    }
);
$bookmark_leftover_rows->find_misses(1);
my $bookmark_leftover_store = GPForum::Service::Community::BookmarkStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::CommunitySchema->new(
        resultsets => { Bookmark => $bookmark_leftover_rows },
    ),
);
my $bookmark_leftover = $bookmark_leftover_store->save_bookmark(
    {
        note        => 'rileggi',
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'user-1',
    }
);
ok( $bookmark_leftover->{skipped},
    'leftover bookmark id race reuses this bookmark' );
is( $bookmark_leftover->{bookmark_id},
    'generated-1', 'leftover bookmark id race keeps this bookmark' );
is( $bookmark_leftover->{user_id},
    'user-1', 'leftover bookmark id race keeps this user' );
is( scalar @{ $bookmark_leftover_rows->created },
    1, 'leftover bookmark id race does not insert a second bookmark' );

my $listed =
  $bookmark_store->list_for_user( 'user-1',
    { target_type => 'thread', limit => $BOOKMARK_LIMIT } );
is( scalar @{$listed},                 1,        'bookmarks can be listed' );
is( $bookmarks->last_query->{user_id}, 'user-1', 'bookmark list filters user' );
is( $bookmarks->last_query->{target_type},
    'thread', 'bookmark list filters target type' );
is( $bookmarks->last_query->{deleted_at},
    undef, 'bookmark list hides deleted rows' );
is( $bookmarks->last_attrs->{rows},
    $BOOKMARK_LIMIT, 'bookmark list applies limit' );

my $removed = $bookmark_store->remove_bookmark('generated-1');
is( $removed->{bookmark_id}, 'generated-1', 'bookmark removal returns id' );
is( $removed->{deleted_at},
    '2026-05-23T12:00:00Z', 'bookmark removal is soft delete' );
is( $bookmarks->find('generated-1')->get_column('deleted_at'),
    '2026-05-23T12:00:00Z', 'bookmark row receives deleted timestamp' );
my $bookmark_row   = $bookmarks->find('generated-1');
my $remove_updates = scalar @{ $bookmark_row->updates };
my $removed_again  = $bookmark_store->remove_bookmark('generated-1');
ok( $removed_again->{skipped}, 'already-removed bookmark is skipped' );
is(
    $removed_again->{deleted_at},
    $removed->{deleted_at},
    'already-removed bookmark keeps the original timestamp'
);
is( scalar @{ $bookmark_row->updates },
    $remove_updates, 'already-removed bookmark does not update the row' );
my $removed_target = $bookmark_store->remove_for_user_target(
    {
        user_id     => 'user-1',
        target_type => 'thread',
        target_id   => 'thread-1',
    }
);
ok( $removed_target->{ok},
    'already-removed bookmark still succeeds by target' );
ok( $removed_target->{skipped},
    'already-removed bookmark is skipped by target' );
is(
    $removed_target->{deleted_at},
    $removed->{deleted_at},
    'already-removed bookmark target keeps the original timestamp'
);
my $removed_status =
  $bookmark_store->status_for_user_target( 'user-1', 'thread', 'thread-1' );
is( $removed_status->{bookmarked}, 0, 'removed bookmark status is inactive' );

my $bookmark_page =
  $bookmark_store->list_page_for_user( 'user-1',
    { target_type => 'thread', limit => $BOOKMARK_LIMIT } );
is( scalar @{ $bookmark_page->{items} }, 1, 'bookmark page returns items' );
is( $bookmark_page->{next_cursor},
    undef, 'bookmark page omits cursor when complete' );

$users->create(
    {
        id         => 'user-1',
        username   => 'giacomo',
        deleted_at => undef,
    }
);
$users->create(
    {
        id         => 'user-2',
        username   => 'alice',
        deleted_at => undef,
    }
);
my $mention_dispatcher = GPForum::Test::NotificationDispatcher->new;
my $mention_store      = GPForum::Service::Community::MentionStore->new(
    schema                  => $schema,
    clock                   => $clock,
    id_service              => GPForum::Test::Id->new,
    notification_dispatcher => $mention_dispatcher,
);
my $stored_mentions = $mention_store->record_for_source(
    {
        source_type => 'post',
        source_id   => 'post-1',
        actor_id    => 'user-1',
        body_source => 'Grazie ' . $AT_SIGN . 'alice e ' . $AT_SIGN . 'ghost',
    }
);

ok( $stored_mentions->{ok}, 'mention recording succeeds' );
is( scalar @{ $stored_mentions->{created} },
    1, 'mention recording creates resolved users only' );
is( $stored_mentions->{created}[0]{mentioned_user_id},
    'user-2', 'mention stores resolved user id' );
is( $stored_mentions->{created}[0]{mentioned_username},
    'alice', 'mention stores normalized username' );
is( scalar @{ $stored_mentions->{skipped} },
    1, 'mention recording reports skipped unresolved users' );
is( $stored_mentions->{skipped}[0]{reason},
    'unknown_user', 'unknown mention skip reason is explicit' );
is( scalar @{ $mentions_rows->created }, 1, 'mention row is upserted' );
is( scalar @{ $stored_mentions->{notifications} },
    1, 'mention recording creates mention notification' );
is( $mention_dispatcher->notifications->[0]{recipient_user_id},
    'user-2', 'mention notification targets mentioned user' );
is( $mention_dispatcher->notifications->[0]{notification_type},
    'mention', 'mention notification has explicit type' );
is( $mention_dispatcher->notifications->[0]{payload}{post_id},
    'post-1', 'mention notification links source post' );

my $duplicate_mentions = $mention_store->record_for_source(
    {
        source_type => 'post',
        source_id   => 'post-1',
        actor_id    => 'user-1',
        body_source => $AT_SIGN . 'alice',
    }
);
is( scalar @{ $duplicate_mentions->{created} },
    0, 'duplicate mention recording is idempotent' );
is( scalar @{ $duplicate_mentions->{skipped} },
    0, 'duplicate mentions do not report user-facing skips' );
is( scalar @{ $duplicate_mentions->{notifications} },
    0, 'duplicate mention creates no notification' );
is( scalar @{ $mentions_rows->created },
    1, 'duplicate mention does not add rows' );

$mentions_rows->find_misses(1);
my $raced_mentions = $mention_store->record_for_source(
    {
        source_type => 'post',
        source_id   => 'post-1',
        actor_id    => 'user-1',
        body_source => $AT_SIGN . 'alice',
    }
);
is( scalar @{ $raced_mentions->{created} },
    0, 'unique mention race does not create a second row' );
is( scalar @{ $raced_mentions->{skipped} },
    0, 'unique mention race does not report a user-facing skip' );
is( scalar @{ $raced_mentions->{notifications} },
    0, 'unique mention race creates no notification' );
is( scalar @{ $mentions_rows->created },
    1, 'unique mention race does not add rows' );

my $mention_pk_users    = GPForum::Test::CommunityResultSet->new;
my $mention_pk_mentions = GPForum::Test::CommunityResultSet->new;
$mention_pk_users->create(
    {
        deleted_at => undef,
        id         => 'user-2',
        username   => 'alice',
    }
);
$mention_pk_mentions->create(
    {
        actor_id           => 'other-actor',
        mention_id         => 'generated-1',
        mentioned_user_id  => 'other-user',
        mentioned_username => 'other',
        source_id          => 'other-post',
        source_type        => 'post',
    }
);
my $mention_pk_store = GPForum::Service::Community::MentionStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::CommunitySchema->new(
        resultsets => {
            Mention => $mention_pk_mentions,
            User    => $mention_pk_users,
        },
    ),
);
my $mention_pk = $mention_pk_store->record_for_source(
    {
        actor_id    => 'user-1',
        body_source => $AT_SIGN . 'alice',
        source_id   => 'post-pk',
        source_type => 'post',
    }
);
is( scalar @{ $mention_pk->{created} },
    1, 'unique mention id collision remints and records' );
is( $mention_pk->{created}[0]{mention_id},
    'generated-2', 'unique mention id collision remints the id' );
is( $mention_pk->{created}[0]{mentioned_user_id},
    'user-2', 'unique mention id collision keeps this mentioned user' );
is( $mention_pk->{created}[0]{source_id},
    'post-pk', 'unique mention id collision keeps this source' );

my $mention_leftover_users      = GPForum::Test::CommunityResultSet->new;
my $mention_leftover_mentions   = GPForum::Test::CommunityResultSet->new;
my $mention_leftover_dispatcher = GPForum::Test::NotificationDispatcher->new;
$mention_leftover_users->create(
    {
        deleted_at => undef,
        id         => 'user-2',
        username   => 'alice',
    }
);
$mention_leftover_mentions->create(
    {
        actor_id           => 'user-1',
        mention_id         => 'generated-1',
        mentioned_user_id  => 'user-2',
        mentioned_username => 'alice',
        source_id          => 'post-leftover',
        source_type        => 'post',
    }
);
$mention_leftover_mentions->find_misses(1);
my $mention_leftover_store = GPForum::Service::Community::MentionStore->new(
    clock                   => GPForum::Test::FixedClock->new,
    id_service              => GPForum::Test::Id->new,
    notification_dispatcher => $mention_leftover_dispatcher,
    schema                  => GPForum::Test::CommunitySchema->new(
        resultsets => {
            Mention => $mention_leftover_mentions,
            User    => $mention_leftover_users,
        },
    ),
);
my $mention_leftover = $mention_leftover_store->record_for_source(
    {
        actor_id    => 'user-1',
        body_source => $AT_SIGN . 'alice',
        source_id   => 'post-leftover',
        source_type => 'post',
    }
);
is( scalar @{ $mention_leftover->{created} },
    0, 'leftover mention id race reuses this mention' );
is( $mention_leftover_mentions->created->[0]{mention_id},
    'generated-1', 'leftover mention id race keeps this mention' );
is( $mention_leftover_mentions->created->[0]{mentioned_user_id},
    'user-2', 'leftover mention id race keeps this mentioned user' );
is( scalar @{ $mention_leftover_mentions->created },
    1, 'leftover mention id race does not insert a second mention' );
is( scalar @{ $mention_leftover->{notifications} },
    1, 'leftover mention id race inserts the missing notification' );

my $self_mention = $mention_store->record_for_source(
    {
        source_type => 'post',
        source_id   => 'post-2',
        actor_id    => 'user-1',
        body_source => $AT_SIGN . 'giacomo',
    }
);

is( scalar @{ $self_mention->{created} },
    0, 'self mention does not create rows' );
is( $self_mention->{skipped}[0]{reason},
    'self_mention', 'self mention skip reason is explicit' );
is( scalar @{ $mentions_rows->created },
    1, 'self mention does not add mention rows' );

my $mention_reader =
  GPForum::Service::Community::MentionReader->new( schema => $schema );
my $mention_page =
  $mention_reader->list_page_for_recipient( 'user-2',
    { limit => $MENTION_READER_LIMIT } );
is( scalar @{ $mention_page->{items} }, 1, 'mention reader returns mentions' );
is( $mention_page->{items}[0]->get_column('mention_id'),
    'generated-1', 'mention reader preserves mention rows' );
is( $mentions_rows->last_query->{'me.mentioned_user_id'},
    'user-2', 'mention reader filters recipient' );
is( $mentions_rows->last_attrs->{order_by}[0]{-desc},
    'me.created_at', 'mention reader qualifies keyset order against actor' );
is( $mentions_rows->last_attrs->{rows},
    $MENTION_FETCH_ROWS, 'mention reader fetches one extra keyset row' );
ok(
    !exists $mentions_rows->last_attrs->{offset},
    'mention reader does not use offset'
);
is( $mention_page->{next_cursor}, undef, 'mention reader omits empty cursor' );

my $mention_cursor = encode_base64url('2026-05-23T12:00:00Z|generated-1');
$mention_reader->list_page_for_recipient(
    'user-2',
    {
        limit => $MENTION_READER_LIMIT,
        after => $mention_cursor,
    }
);
ok(
    exists $mentions_rows->last_query->{-or},
    'mention reader applies keyset cursor predicate'
);

my $reputation = GPForum::Service::Community::ReputationLedger->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);
my $reputation_result = $reputation->record_event(
    {
        user_id       => 'user-1',
        actor_id      => 'moderator-1',
        source_type   => 'post',
        source_id     => 'post-1',
        delta         => $REPUTATION_DELTA,
        reason        => 'helpful_post',
        current_score => $CURRENT_SCORE,
    }
);

ok( $reputation_result->{ok}, 'reputation event succeeds' );
is( $reputation_result->{event}{reputation_event_id},
    'generated-1', 'reputation event id is generated' );
is( $reputation_result->{event}{delta},
    $REPUTATION_DELTA, 'reputation event stores delta' );
is( $reputation_result->{snapshot}{score},
    $EXPECTED_SCORE, 'trust snapshot stores calculated score' );
is( $reputation_result->{snapshot}{trust_level},
    $EXPECTED_TRUST_LEVEL, 'trust snapshot stores trust level' );
is( $reputation_result->{snapshot}{version},
    $DEFAULT_VERSION, 'trust snapshot stores version' );
is( scalar @{ $reputation_events->created },
    1, 'reputation event row is inserted' );
is( scalar @{ $trust_snapshots->created }, 1,
    'trust snapshot row is upserted' );
is( $users->find('user-1')->get_column('trust_level'),
    $EXPECTED_TRUST_LEVEL, 'ledger syncs the user trust level' );
is( scalar @{ $users->find('user-1')->updates },
    1, 'first reputation event writes the user trust level' );

my $follow_on = $reputation->record_event(
    {
        actor_id    => 'moderator-1',
        delta       => $REPUTATION_DELTA,
        reason      => 'helpful_post',
        source_id   => 'post-2',
        source_type => 'post',
        user_id     => 'user-1',
    }
);
ok( $follow_on->{ok}, 'follow-on reputation event succeeds' );
is( $follow_on->{snapshot}{score},
    $FOLLOW_ON_SCORE, 'ledger continues from the stored snapshot score' );
is( scalar @{ $reputation_events->created },
    $FOLLOW_ON_EVENTS, 'follow-on reputation event inserts another row' );
is( scalar @{ $users->find('user-1')->updates },
    1, 'unchanged trust level does not restamp the user' );

my $replayed = $reputation->record_event(
    {
        actor_id    => 'moderator-1',
        delta       => $REPUTATION_DELTA,
        reason      => 'helpful_post',
        source_id   => 'post-2',
        source_type => 'post',
        user_id     => 'user-1',
    }
);
ok( $replayed->{skipped}, 'duplicate source reputation event is skipped' );
is( $replayed->{snapshot}{score},
    $FOLLOW_ON_SCORE, 'replayed reputation keeps the stored snapshot score' );
is( scalar @{ $reputation_events->created },
    $FOLLOW_ON_EVENTS, 'replayed reputation does not insert another row' );

$reputation_events->find_misses(1);
my $raced = $reputation->record_event(
    {
        actor_id    => 'moderator-1',
        delta       => $REPUTATION_DELTA,
        reason      => 'helpful_post',
        source_id   => 'post-2',
        source_type => 'post',
        user_id     => 'user-1',
    }
);
ok( $raced->{skipped}, 'reputation unique race replays the stored event' );
is( $raced->{snapshot}{score},
    $FOLLOW_ON_SCORE, 'reputation unique race keeps the stored snapshot' );
is( scalar @{ $reputation_events->created },
    $FOLLOW_ON_EVENTS, 'reputation unique race does not insert another row' );

my $rep_pk_events = GPForum::Test::CommunityResultSet->new;
$rep_pk_events->create(
    {
        actor_id            => 'other-moderator',
        delta               => 1,
        reason              => 'other',
        reputation_event_id => 'generated-1',
        source_id           => 'other-post',
        source_type         => 'post',
        user_id             => 'other-user',
    }
);
my $rep_pk_users = GPForum::Test::CommunityResultSet->new;
$rep_pk_users->create(
    {
        id          => 'user-1',
        trust_level => 0,
    }
);
my $rep_pk_store = GPForum::Service::Community::ReputationLedger->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::CommunitySchema->new(
        resultsets => {
            ReputationEvent    => $rep_pk_events,
            TrustScoreSnapshot => GPForum::Test::CommunityResultSet->new,
            User               => $rep_pk_users,
        },
    ),
);
my $rep_pk = $rep_pk_store->record_event(
    {
        actor_id      => 'moderator-1',
        current_score => $CURRENT_SCORE,
        delta         => $REPUTATION_DELTA,
        reason        => 'helpful_post',
        source_id     => 'post-pk',
        source_type   => 'post',
        user_id       => 'user-1',
    }
);
ok( $rep_pk->{ok}, 'unique reputation id collision remints and records' );
ok( !$rep_pk->{skipped},
    'unique reputation id collision does not replay another event' );
is( $rep_pk->{event}{reputation_event_id},
    'generated-2', 'unique reputation id collision remints the id' );
is( $rep_pk->{event}{user_id},
    'user-1', 'unique reputation id collision keeps this user' );

my $rep_leftover_events = GPForum::Test::CommunityResultSet->new;
$rep_leftover_events->create(
    {
        actor_id            => 'moderator-1',
        delta               => $REPUTATION_DELTA,
        reason              => 'helpful_post',
        reputation_event_id => 'generated-1',
        source_id           => 'post-leftover',
        source_type         => 'post',
        user_id             => 'user-1',
    }
);
my $rep_leftover_snapshots = GPForum::Test::CommunityResultSet->new;
my $rep_leftover_users     = GPForum::Test::CommunityResultSet->new;
$rep_leftover_users->create(
    {
        id          => 'user-1',
        trust_level => 0,
    }
);
my $rep_leftover_store = GPForum::Service::Community::ReputationLedger->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::CommunitySchema->new(
        resultsets => {
            ReputationEvent    => $rep_leftover_events,
            TrustScoreSnapshot => $rep_leftover_snapshots,
            User               => $rep_leftover_users,
        },
    ),
);
my $rep_leftover = $rep_leftover_store->record_event(
    {
        actor_id      => 'moderator-1',
        current_score => $CURRENT_SCORE,
        delta         => $REPUTATION_DELTA,
        reason        => 'helpful_post',
        source_id     => 'post-leftover',
        source_type   => 'post',
        user_id       => 'user-1',
    }
);
ok( $rep_leftover->{skipped}, 'leftover reputation id race reuses this event' );
is( $rep_leftover->{event}{reputation_event_id},
    'generated-1', 'leftover reputation id race keeps this event' );
is( $rep_leftover->{snapshot}{score},
    $EXPECTED_SCORE,
    'leftover reputation id race inserts the missing snapshot' );
is( scalar @{ $rep_leftover_events->created },
    1, 'leftover reputation id race does not insert a second event' );

my $missing_source = $reputation->record_event(
    {
        actor_id    => 'moderator-1',
        delta       => $REPUTATION_DELTA,
        reason      => 'helpful_post',
        source_type => 'post',
        user_id     => 'user-1',
    }
);
ok( $missing_source->{skipped}, 'reputation without source_id is skipped' );
is( $missing_source->{reason},
    'missing_source', 'reputation names a missing source_id' );
is( scalar @{ $reputation_events->created },
    $FOLLOW_ON_EVENTS, 'reputation without source_id does not insert a row' );

my $seed_snapshot = GPForum::Test::CommunityRow->new(
    data => {
        calculated_at => '2026-05-23T12:00:00Z',
        score         => $SNAPSHOT_SEED_SCORE,
        trust_level   => 1,
        user_id       => 'user-2',
        version       => $DEFAULT_VERSION,
    }
);
$trust_snapshots->rows->{'user-2'} = $seed_snapshot;
$trust_snapshots->find_misses(1);
my $raced_snapshot = $reputation->record_event(
    {
        actor_id    => 'moderator-1',
        delta       => $REPUTATION_DELTA,
        reason      => 'helpful_post',
        source_id   => 'post-9',
        source_type => 'post',
        user_id     => 'user-2',
    }
);
ok( $raced_snapshot->{ok}, 'unique trust snapshot race applies the delta' );
is( $raced_snapshot->{snapshot}{score},
    $SNAPSHOT_RACE_SCORE,
    'unique trust snapshot race adds the delta to the winning row' );
is( scalar @{ $trust_snapshots->created },
    1, 'unique trust snapshot race does not insert a second snapshot' );
is( scalar @{ $seed_snapshot->updates },
    1, 'unique trust snapshot race updates the winning snapshot' );

my $feed_projector =
  GPForum::Service::Community::FeedProjector->new( schema => $schema, );
my $feed = $feed_projector->project_item(
    {
        user_ids   => [ 'user-1', 'user-2', 'user-1' ],
        item_type  => 'post',
        item_id    => 'post-1',
        created_at => '2026-05-23T12:00:00Z',
    }
);

ok( $feed->{ok}, 'feed projection succeeds' );
is( $feed->{projected}, $FEED_USER_COUNT,
    'feed projection deduplicates users' );
is( scalar @{ $feed_items->created },
    $FEED_USER_COUNT, 'feed items are upserted' );
is( $feed->{items}[0]{user_id},    'user-1', 'feed item stores first user' );
is( $feed->{items}[1]{user_id},    'user-2', 'feed item stores second user' );
is( $feed->{items}[0]{rank_score}, $DEFAULT_RANK, 'feed item defaults rank' );
is( $feed->{items}[0]{visibility_version},
    $DEFAULT_VERSION, 'feed item carries visibility version' );
is( $feed->{items}[0]{permission_version},
    $DEFAULT_VERSION, 'feed item carries permission version' );
my $created_count = scalar @{ $feed_items->created };
my $same_feed     = $feed_projector->project_item(
    {
        user_ids   => [ 'user-1', 'user-2' ],
        item_type  => 'post',
        item_id    => 'post-1',
        created_at => '2026-05-23T12:00:00Z',
    }
);
ok( $same_feed->{ok}, 'unchanged feed projection still succeeds' );
ok( $same_feed->{items}[0]{skipped},
    'unchanged feed projection skips the first recipient' );
ok( $same_feed->{items}[1]{skipped},
    'unchanged feed projection skips the second recipient' );
is( $same_feed->{projected},
    $FEED_USER_COUNT, 'unchanged feed projection still reports recipients' );
is( scalar @{ $feed_items->created },
    $created_count, 'unchanged feed projection does not insert another row' );
$feed_items->find_misses(1);
my $raced_feed = $feed_projector->project_item(
    {
        user_ids   => [ 'user-1', 'user-2' ],
        item_type  => 'post',
        item_id    => 'post-1',
        created_at => '2026-05-23T12:00:00Z',
    }
);
ok( $raced_feed->{items}[0]{skipped},
    'unique feed race skips the first recipient' );
ok( $raced_feed->{items}[1]{skipped},
    'unique feed race skips the second recipient' );
is( $raced_feed->{projected},
    $FEED_USER_COUNT, 'unique feed race still reports recipients' );
is( scalar @{ $feed_items->created },
    $created_count, 'unique feed race does not insert another row' );
my $bumped_feed = $feed_projector->project_item(
    {
        created_at         => '2026-05-23T12:00:00Z',
        item_id            => 'post-1',
        item_type          => 'post',
        user_ids           => [ 'user-1', 'user-2' ],
        visibility_version => 2,
    }
);
ok( !$bumped_feed->{items}[0]{skipped},
    'feed projection writes after a visibility version bump' );
is( scalar @{ $feed_items->created },
    $created_count, 'visibility version bump does not insert another row' );

my $feed_reader =
  GPForum::Service::Community::FeedReader->new( schema => $schema );
my $feed_page =
  $feed_reader->list_page_for_user( 'user-1', { limit => $FEED_READER_LIMIT } );
is( scalar @{ $feed_page->{items} },
    $FEED_USER_COUNT, 'feed reader returns projection rows' );
is( $feed_page->{items}[0]->get_column('item_id'),
    'post-1', 'feed reader preserves feed item rows' );
is( $feed_items->last_query->{user_id}, 'user-1', 'feed reader filters user' );
is( $feed_items->last_attrs->{rows},
    $FEED_FETCH_ROWS, 'feed reader fetches one extra keyset row' );
ok(
    !exists $feed_items->last_attrs->{offset},
    'feed reader does not use offset'
);
is( $feed_page->{next_cursor}, undef, 'feed reader omits empty cursor' );

my $feed_cursor = encode_base64url('2026-05-23T12:00:00Z|post-1');
$feed_reader->list_page_for_user(
    'user-1',
    {
        limit => $FEED_READER_LIMIT,
        after => $feed_cursor,
    }
);
ok(
    exists $feed_items->last_query->{-or},
    'feed reader applies keyset cursor predicate'
);

my $withdrawn = $feed_projector->remove_item(
    {
        item_id   => 'post-1',
        item_type => 'post',
    }
);
ok( $withdrawn->{ok}, 'feed removal succeeds' );
is( $withdrawn->{removed}, $FEED_USER_COUNT,
    'feed removal deletes every projected user row' );
is( scalar @{ $feed_items->deleted },
    $FEED_USER_COUNT, 'feed item rows are deleted' );

my $hidden_page =
  $feed_reader->list_page_for_user( 'user-1', { limit => $FEED_READER_LIMIT } );
is( scalar @{ $hidden_page->{items} },
    0, 'feed reader hides removed moderated items' );

my $restored = $feed_projector->project_item(
    {
        created_at => '2026-05-23T12:00:00Z',
        item_id    => 'post-1',
        item_type  => 'post',
        user_ids   => [ 'user-1', 'user-2' ],
    }
);
ok( $restored->{ok}, 'feed restore reuses project_item' );
is( $restored->{projected},
    $FEED_USER_COUNT, 'feed restore projects the original recipients' );

my $thread_feed = $feed_projector->project_item(
    {
        created_at => '2026-05-23T12:00:00Z',
        item_id    => 'thread-1',
        item_type  => 'thread',
        user_ids   => [ 'user-1', 'user-2' ],
    }
);
ok( $thread_feed->{ok}, 'thread feed projection succeeds' );
is( $thread_feed->{projected},
    $FEED_USER_COUNT, 'thread feed projects to the same recipients' );

my $cascade = $feed_projector->remove_thread('thread-1');
ok( $cascade->{ok}, 'thread feed cascade succeeds' );
is(
    $cascade->{removed},
    $FEED_USER_COUNT + $FEED_USER_COUNT,
    'thread cascade deletes thread and post feed rows'
);
is( $cascade->{posts_removed},
    $FEED_USER_COUNT, 'thread cascade deletes post feed rows' );

my $cascade_page =
  $feed_reader->list_page_for_user( 'user-1', { limit => $FEED_READER_LIMIT } );
is( scalar @{ $cascade_page->{items} },
    0, 'feed reader hides posts after the parent thread is deleted' );

1;
