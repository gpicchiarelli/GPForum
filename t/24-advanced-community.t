package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Community::BookmarkStore;
use GPForum::Service::Community::FeedProjector;
use GPForum::Service::Community::MentionExtractor;
use GPForum::Service::Community::MentionStore;
use GPForum::Service::Community::ReputationLedger;
use GPForum::Test::CommunityResultSet;
use GPForum::Test::CommunitySchema;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;

our $VERSION = '0.001';

const my $EXPECTED_TESTS       => 57;
const my $BOOKMARK_LIMIT       => 20;
const my $MENTION_COUNT        => 2;
const my $DEFAULT_RANK         => 0;
const my $REPUTATION_DELTA     => 15;
const my $CURRENT_SCORE        => 40;
const my $EXPECTED_SCORE       => 55;
const my $EXPECTED_TRUST_LEVEL => 2;
const my $FEED_USER_COUNT      => 2;
const my $DEFAULT_VERSION      => 1;
const my $AT_CODE              => 64;
const my $AT_SIGN              => chr $AT_CODE;

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
my $schema            = GPForum::Test::CommunitySchema->new(
    resultsets => {
        Bookmark           => $bookmarks,
        Mention            => $mentions_rows,
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
my $mention_store = GPForum::Service::Community::MentionStore->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
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
is( scalar @{ $mentions_rows->created },
    1, 'duplicate mention does not add rows' );

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

1;
