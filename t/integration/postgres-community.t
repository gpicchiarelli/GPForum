# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Infrastructure::Id;
use GPForum::Schema;
use GPForum::Service::Community::BookmarkStore;
use GPForum::Service::Community::FeedProjector;
use GPForum::Service::Community::FeedReader;
use GPForum::Service::Community::MentionReader;
use GPForum::Service::Community::MentionStore;
use GPForum::Service::Community::ReputationLedger;
use GPForum::Service::Forum::Readability;
use GPForum::Service::Notification::Dispatcher;
use GPForum::Test::FixedClock;
use GPForum::Test::PgDatabase;
use GPForum::Test::ScriptedId;

our $VERSION = '0.001';

const my $NOW    => '2026-05-23T12:00:00Z';
const my $LATER  => '2026-05-23T13:00:00Z';
const my $EARLY  => '2026-05-23T09:00:00Z';
const my $MIDDLE => '2026-05-23T10:00:00Z';
const my $LATE   => '2026-05-23T11:00:00Z';

const my $LIST_LIMIT      => 20;
const my $PAGE_LIMIT      => 2;
const my $MAX_PAGES       => 100;
const my $RECIPIENTS      => 3;
const my $DELTA           => 15;
const my $DECLARED_SCORE  => 40;
const my $FIRST_SCORE     => 55;
const my $FOLLOW_ON_SCORE => 70;
const my $RACED_SCORE     => 85;
const my $SEED_SCORE      => 10;
const my $SEED_RACE_SCORE => 25;
const my $TRUST_LEVEL     => 2;
const my $FOLLOW_ON_ROWS  => 2;
const my $RACED_ROWS      => 3;
const my $INTEGER_MAX     => 2_147_483_647;
const my $TIED            => 4;

const my $USER_SQL => join q{ },
  'INSERT INTO users (id, username, display_name, email_normalized,',
  q{password_hash, status) VALUES (?, ?, ?, ?, 'x', 'active')};
const my $SPACE_SQL => join q{ },
  'INSERT INTO spaces (space_id, slug, title)',
  q{VALUES (?, 'community', 'Community')};
const my $CATEGORY_SQL => join q{ },
  'INSERT INTO categories (category_id, space_id, slug, title, visibility)',
  'VALUES (?, ?, ?, ?, ?)';
const my $THREAD_SQL => join q{ },
  'INSERT INTO threads (thread_id, category_id, author_user_id, title, slug)',
  'VALUES (?, ?, ?, ?, ?)';
const my $POST_SQL => join q{ },
  'INSERT INTO posts (post_id, thread_id, author_user_id, position)',
  'VALUES (?, ?, ?, ?)';
const my $BOOKMARK_SQL => join q{ },
  'INSERT INTO bookmarks (bookmark_id, user_id, target_type, target_id, note)',
  q{VALUES (?, ?, 'thread', ?, 'rileggi')};
const my $MENTION_SQL => join q{ },
  'INSERT INTO mentions (mention_id, source_type, source_id, actor_id,',
  'mentioned_user_id, mentioned_username, created_at)',
  q{VALUES (?, 'post', ?, ?, ?, ?, ?)};
const my $EVENT_SQL => join q{ },
  'INSERT INTO reputation_events (reputation_event_id, user_id, actor_id,',
  q{source_type, source_id, delta, reason) VALUES (?, ?, ?, 'post', ?, ?,},
  q{'helpful_post')};
const my $SNAPSHOT_SQL => join q{ },
  'INSERT INTO trust_score_snapshots (user_id, score, trust_level)',
  'VALUES (?, ?, 1)';

# A timestamp as the clock writes it, whatever zone the server returns it in.
const my $UTC_SQL => join q{ },
  q{SELECT to_char(?::timestamptz AT TIME ZONE 'UTC',},
  q{'YYYY-MM-DD"T"HH24:MI:SS"Z"')};
const my $BOOKMARK_ROW_SQL => 'SELECT * FROM bookmarks WHERE bookmark_id = ?';
const my $MENTION_ROW_SQL  => 'SELECT * FROM mentions WHERE mention_id = ?';
const my $TARGET_BOOKMARKS_SQL => join q{ },
  'SELECT count(*) FROM bookmarks',
  'WHERE user_id = ? AND target_type = ? AND target_id = ?';
const my $ACTIVE_BOOKMARKS_SQL => join q{ },
  'SELECT bookmark_id FROM bookmarks WHERE user_id = ? AND deleted_at IS NULL',
  'ORDER BY created_at DESC, bookmark_id DESC';
const my $SOURCE_MENTIONS_SQL => join q{ },
  'SELECT count(*) FROM mentions',
  q{WHERE source_type = 'post' AND source_id = ? AND mentioned_user_id = ?};
const my $SOURCE_ALL_MENTIONS_SQL =>
  q{SELECT count(*) FROM mentions WHERE source_type = 'post' AND source_id = ?};
const my $RECIPIENT_MENTIONS_SQL => join q{ },
  'SELECT mention_id FROM mentions WHERE mentioned_user_id = ?',
  'ORDER BY created_at DESC, mention_id DESC';
const my $NOTIFICATIONS_SQL => join q{ },
  'SELECT count(*) FROM notifications',
  q{WHERE recipient_user_id = ? AND notification_type = 'mention'},
  'AND source_id = ?';
const my $USER_EVENTS_SQL =>
  'SELECT count(*) FROM reputation_events WHERE user_id = ?';
const my $SOURCE_EVENTS_SQL => join q{ },
  'SELECT count(*) FROM reputation_events',
  q{WHERE user_id = ? AND source_type = 'post' AND source_id = ?};
const my $EVENT_USER_SQL => join q{ },
  'SELECT user_id FROM reputation_events WHERE reputation_event_id = ?';
const my $SCORE_SQL =>
  'SELECT score FROM trust_score_snapshots WHERE user_id = ?';
const my $SNAPSHOTS_SQL =>
  'SELECT count(*) FROM trust_score_snapshots WHERE user_id = ?';
const my $TRUST_SQL => 'SELECT trust_level FROM users WHERE id = ?';
const my $FEED_ROWS_SQL => join q{ },
  'SELECT count(*) FROM user_feed_items',
  'WHERE item_type = ? AND item_id = ?';
const my $USER_FEED_SQL => join q{ },
  'SELECT item_id FROM user_feed_items WHERE user_id = ?',
  'ORDER BY created_at DESC, item_id DESC';

# The transaction that last wrote a row: a row that keeps it was not
# written since, not even with the values it already held.
const my %VERSION_SQL => (
    bookmark => 'SELECT xmin::text FROM bookmarks WHERE bookmark_id = ?',
    user     => 'SELECT xmin::text FROM users WHERE id = ?',
);

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# Bookmarks, mentions, the personal feed and the reputation ledger on
# PostgreSQL. These ran on a fake ORM in t/24 whose search ignored its query:
# a removed bookmark was still listed and one member's feed held another's
# rows, and the tests pinned both. A race was a find told to miss; here a
# rival connection commits the competing row between the store's look-up and
# its insert, and PostgreSQL raises the conflict the store recovers from.
my $clone     = GPForum::Test::PgDatabase->fresh;
my $community = _context($clone);

_bookmark_lifecycle($community);
_bookmark_id_collision($community);
_bookmark_id_race($community);
_bookmark_target_race($community);
_bookmark_list($community);
_bookmark_pages($community);
_bookmark_readability($community);
_mention_recording($community);
_mention_race($community);
_mention_id_collision($community);
_mention_id_race($community);
_self_mention($community);
_mention_pages($community);
_mention_readability($community);
_reputation_ledger($community);
_reputation_atomic($community);
_reputation_race($community);
_reputation_id_collision($community);
_reputation_id_race($community);
_snapshot_race($community);
_feed_projection($community);
_feed_pages($community);
_feed_readability($community);

$community->{rival}->storage->disconnect;

done_testing();

sub _context {
    my ($database) = @_;

    my $ctx = {
        clock  => GPForum::Test::FixedClock->new,
        dbh    => $database->dbh,
        ids    => GPForum::Infrastructure::Id->new,
        rival  => _rival_schema($database),
        schema => $database->schema,
        serial => 0,
    };
    $ctx->{users} = { map { $_ => _user( $ctx, $_ ) }
          qw(giacomo alice bob carol dave erin moderator) };
    _forum($ctx);

    return $ctx;
}

# A second connection to the same database: the concurrent request.
sub _rival_schema {
    my ($database) = @_;

    local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;

    return GPForum::Schema->connect_from_config(
        GPForum::Config->from_environment );
}

sub _user {
    my ( $ctx, $name ) = @_;

    my $id = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $USER_SQL, undef, $id, $name, ucfirst $name,
        "$name\@example.test" );

    return $id;
}

# A public category and a private one, which no member without a grant can
# read; one thread and post in each to start from.
sub _forum {
    my ($ctx) = @_;

    my $space = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $SPACE_SQL, undef, $space );
    for my $visibility (qw(public private)) {
        my $category = $ctx->{ids}->uuid;
        $ctx->{dbh}->do( $CATEGORY_SQL, undef, $category, $space,
            $visibility, ucfirst $visibility, $visibility );
        $ctx->{category}{$visibility} = $category;
    }
    $ctx->{private_thread} = _thread( $ctx, 'private' );
    $ctx->{private_post}   = _post( $ctx, $ctx->{private_thread} );
    $ctx->{thread}         = _thread($ctx);

    return;
}

sub _thread {
    my ( $ctx, $visibility ) = @_;

    my $id     = $ctx->{ids}->uuid;
    my $serial = ++$ctx->{serial};
    $ctx->{dbh}->do(
        $THREAD_SQL, undef, $id,
        $ctx->{category}{ $visibility // 'public' },
        $ctx->{users}{giacomo},
        "Thread $serial",
        "thread-$serial"
    );

    return $id;
}

sub _post {
    my ( $ctx, $thread ) = @_;

    my $id = $ctx->{ids}->uuid;
    $ctx->{dbh}->do(
        $POST_SQL, undef, $id,
        $thread // $ctx->{thread},
        $ctx->{users}{giacomo},
        ++$ctx->{serial}
    );

    return $id;
}

sub _bookmark_lifecycle {
    my ($ctx) = @_;

    my $store  = _bookmarks($ctx);
    my $user   = $ctx->{users}{giacomo};
    my $thread = _thread($ctx);
    my %target = (
        target_id   => $thread,
        target_type => 'thread',
        user_id     => $user,
    );
    my $bookmark = $store->create_bookmark( { %target, note => 'rileggi' } );
    my $id       = $bookmark->{bookmark_id};
    ok( GPForum::Infrastructure::Id->is_uuid($id), 'bookmark id is generated' );
    is( $bookmark->{user_id},     $user,     'bookmark stores owner' );
    is( $bookmark->{target_type}, 'thread',  'bookmark stores target type' );
    is( $bookmark->{target_id},   $thread,   'bookmark stores target id' );
    is( $bookmark->{note},        'rileggi', 'bookmark stores note' );
    is( $bookmark->{created_at},  $NOW,      'bookmark stores creation time' );
    my $row = _row( $ctx, $BOOKMARK_ROW_SQL, $id );
    is_deeply(
        [ @{$row}{qw(user_id target_type target_id note deleted_at)} ],
        [ $user, 'thread', $thread, 'rileggi', undef ],
        'bookmark row is inserted'
    );
    is( _utc( $ctx, $row->{created_at} ),
        $NOW, 'bookmark row keeps the creation time' );

    my $status = $store->status_for_user_target( $user, 'thread', $thread );
    is( $status->{bookmarked},  1,   'bookmark status is active' );
    is( $status->{bookmark_id}, $id, 'bookmark status exposes bookmark id' );

    _bookmark_saved_again( $ctx, $store, \%target, $id );
    _bookmark_removal( $ctx, $store, \%target, $id );

    return;
}

sub _bookmark_saved_again {
    my ( $ctx, $store, $target, $id ) = @_;

    my $saved = $store->save_bookmark( { %{$target}, note => 'aggiornato' } );
    is( $saved->{bookmark_id}, $id,
        'saving an existing bookmark is idempotent' );
    is( $saved->{note}, 'aggiornato', 'save updates bookmark note' );
    is( _row( $ctx, $BOOKMARK_ROW_SQL, $id )->{note},
        'aggiornato', 'and the row holds the new note' );
    is( _value( $ctx, $TARGET_BOOKMARKS_SQL, _target_key($target) ),
        1, 'idempotent bookmark save does not insert a duplicate' );

    my $version = _version( $ctx, bookmark => $id );
    my $again   = $store->save_bookmark( { %{$target}, note => 'aggiornato' } );
    ok( $again->{skipped}, 'already-active bookmark save is skipped' );
    is( $again->{note}, 'aggiornato',
        'already-active bookmark keeps the note' );
    is( _version( $ctx, bookmark => $id ),
        $version, 'already-active bookmark does not update the row' );

    return;
}

sub _bookmark_removal {
    my ( $ctx, $store, $target, $id ) = @_;

    my $removed = $store->remove_bookmark($id);
    is( $removed->{bookmark_id}, $id,  'bookmark removal returns id' );
    is( $removed->{deleted_at},  $NOW, 'bookmark removal is soft delete' );
    is( _utc( $ctx, _row( $ctx, $BOOKMARK_ROW_SQL, $id )->{deleted_at} ),
        $NOW, 'bookmark row receives deleted timestamp' );

    # An hour on, so a second removal that restamped the row would show.
    $ctx->{clock}->iso8601($LATER);
    my $version = _version( $ctx, bookmark => $id );
    my $again   = $store->remove_bookmark($id);
    ok( $again->{skipped}, 'already-removed bookmark is skipped' );
    is( _utc( $ctx, $again->{deleted_at} ),
        $NOW, 'already-removed bookmark keeps the original timestamp' );
    is( _version( $ctx, bookmark => $id ),
        $version, 'already-removed bookmark does not update the row' );

    my $by_target = $store->remove_for_user_target($target);
    ok( $by_target->{ok}, 'already-removed bookmark still succeeds by target' );
    ok( $by_target->{skipped},
        'already-removed bookmark is skipped by target' );
    is( _utc( $ctx, $by_target->{deleted_at} ),
        $NOW, 'already-removed bookmark target keeps the original timestamp' );
    $ctx->{clock}->iso8601($NOW);

    is( $store->status_for_user_target( _target_key($target) )->{bookmarked},
        0, 'removed bookmark status is inactive' );
    my $page = $store->list_page_for_user( $target->{user_id},
        { limit => $LIST_LIMIT, target_type => 'thread' } );
    is_deeply( $page->{items}, [], 'a removed bookmark is not listed' );
    is( $page->{next_cursor}, undef,
        'bookmark page omits cursor when complete' );

    my $restored = $store->save_bookmark( { %{$target}, note => 'di nuovo' } );
    is( $restored->{bookmark_id},
        $id, 'saving a removed bookmark restores the same row' );
    is( _row( $ctx, $BOOKMARK_ROW_SQL, $id )->{deleted_at},
        undef, 'and clears its deleted timestamp' );

    return;
}

# The id the store mints is another member's bookmark: it mints a new one.
sub _bookmark_id_collision {
    my ($ctx) = @_;

    my $taken = $ctx->{ids}->uuid;
    $ctx->{dbh}
      ->do( $BOOKMARK_SQL, undef, $taken, $ctx->{users}{bob}, _thread($ctx) );
    my $user   = $ctx->{users}{giacomo};
    my $thread = _thread($ctx);
    my $saved =
      _bookmarks( $ctx,
        id_service => GPForum::Test::ScriptedId->new( next_ids => [$taken] ) )
      ->save_bookmark(
        {
            note        => 'rileggi',
            target_id   => $thread,
            target_type => 'thread',
            user_id     => $user,
        }
      );
    ok( !$saved->{skipped}, 'unique bookmark id collision remints and saves' );
    ok(
        GPForum::Infrastructure::Id->is_uuid( $saved->{bookmark_id} )
          && $saved->{bookmark_id} ne $taken,
        'unique bookmark id collision remints the id'
    );
    is( $saved->{user_id}, $user,
        'unique bookmark id collision keeps this user' );
    is( $saved->{target_id}, $thread,
        'unique bookmark id collision keeps this target' );
    is(
        _row( $ctx, $BOOKMARK_ROW_SQL, $taken )->{user_id},
        $ctx->{users}{bob},
        'and leaves the other bookmark alone'
    );

    return;
}

# The rival commits this very bookmark, under the id the store is about to
# use, between the store's look-up and its insert: the store finds it by its
# target and reuses it instead of minting a second.
sub _bookmark_id_race {
    my ($ctx) = @_;

    my $id     = $ctx->{ids}->uuid;
    my $user   = $ctx->{users}{giacomo};
    my $thread = _thread($ctx);
    my $saved  = _racing(
        $ctx,
        'bookmarks',
        sub {
            my ($rival) = @_;
            $rival->storage->dbh->do( $BOOKMARK_SQL, undef, $id, $user,
                $thread );
            return;
        },
        sub {
            return _bookmarks( $ctx,
                id_service =>
                  GPForum::Test::ScriptedId->new( next_ids => [$id] ) )
              ->save_bookmark(
                {
                    note        => 'rileggi',
                    target_id   => $thread,
                    target_type => 'thread',
                    user_id     => $user,
                }
              );
        }
    );
    ok( $saved->{skipped}, 'leftover bookmark id race reuses this bookmark' );
    is( $saved->{bookmark_id}, $id,
        'leftover bookmark id race keeps this bookmark' );
    is( $saved->{user_id}, $user, 'leftover bookmark id race keeps this user' );
    is( _value( $ctx, $TARGET_BOOKMARKS_SQL, $user, 'thread', $thread ),
        1, 'leftover bookmark id race does not insert a second bookmark' );

    return;
}

# A concurrent request saves the same bookmark, under its own id, between
# this store's look-up and its insert: the store restores the winning row.
sub _bookmark_target_race {
    my ($ctx) = @_;

    my $user   = $ctx->{users}{giacomo};
    my $thread = _thread($ctx);
    my %target = (
        target_id   => $thread,
        target_type => 'thread',
        user_id     => $user,
    );
    my $winner;
    my $saved = _racing(
        $ctx,
        'bookmarks',
        sub {
            my ($rival) = @_;
            $winner = _bookmarks( $ctx, schema => $rival )
              ->save_bookmark( { %target, note => 'rileggi' } );
            return;
        },
        sub {
            return _bookmarks($ctx)
              ->save_bookmark( { %target, note => 'aggiornato' } );
        }
    );
    is(
        $saved->{bookmark_id},
        $winner->{bookmark_id},
        'bookmark unique race returns the existing bookmark'
    );
    is( _value( $ctx, $TARGET_BOOKMARKS_SQL, $user, 'thread', $thread ),
        1, 'bookmark unique race does not insert a second row' );
    is( _row( $ctx, $BOOKMARK_ROW_SQL, $winner->{bookmark_id} )->{note},
        'aggiornato', 'bookmark unique race restores the winning row' );

    return;
}

sub _bookmark_list {
    my ($ctx) = @_;

    my $store   = _bookmarks($ctx);
    my $user    = $ctx->{users}{carol};
    my @threads = ( _thread($ctx), _thread($ctx) );
    my $gone    = _thread($ctx);
    for my $thread ( @threads, $gone ) {
        $store->save_bookmark(
            { target_id => $thread, target_type => 'thread', user_id => $user }
        );
    }
    $store->remove_for_user_target(
        { target_id => $gone, target_type => 'thread', user_id => $user } );
    $store->save_bookmark(
        {
            target_id   => _post( $ctx, $threads[0] ),
            target_type => 'post',
            user_id     => $user,
        }
    );
    $store->save_bookmark(
        {
            target_id   => _thread($ctx),
            target_type => 'thread',
            user_id     => $ctx->{users}{bob},
        }
    );

    my $listed = $store->list_for_user( $user,
        { limit => $LIST_LIMIT, target_type => 'thread' } );
    is_deeply(
        [ sort map { $_->get_column('target_id') } @{$listed} ],
        [ sort @threads ],
        'bookmarks can be listed'
    );
    ok( !( grep { $_->get_column('user_id') ne $user } @{$listed} ),
        'bookmark list filters user' );
    ok( !( grep { $_->get_column('target_type') ne 'thread' } @{$listed} ),
        'bookmark list filters target type' );
    ok( !( grep { $_->get_column('target_id') eq $gone } @{$listed} ),
        'bookmark list hides deleted rows' );
    is(
        scalar @{
            $store->list_for_user( $user,
                { limit => 1, target_type => 'thread' } )
        },
        1,
        'bookmark list applies limit'
    );

    return;
}

# Several bookmarks at the same instant, inserted in ascending id order, so
# the pages run through a tie that only the id breaks. The ids are lined up
# sorted: minted as they come, uuids from the same millisecond fall either
# way round.
sub _bookmark_pages {
    my ($ctx) = @_;

    my @instants = ( $EARLY, $MIDDLE, ($LATE) x $TIED );
    my @ids      = sort map { $ctx->{ids}->uuid } @instants;
    my $store    = _bookmarks( $ctx,
        id_service => GPForum::Test::ScriptedId->new( next_ids => \@ids ) );
    my $user = $ctx->{users}{dave};
    for my $at (@instants) {
        $ctx->{clock}->iso8601($at);
        $store->save_bookmark(
            {
                target_id   => _thread($ctx),
                target_type => 'thread',
                user_id     => $user,
            }
        );
    }
    $ctx->{clock}->iso8601($NOW);

    my $every =
      $ctx->{dbh}->selectcol_arrayref( $ACTIVE_BOOKMARKS_SQL, undef, $user );
    is_deeply(
        _walk(
            sub {
                my ($after) = @_;
                return $store->list_page_for_user( $user,
                    { after => $after, limit => 1 } );
            },
            'bookmark_id'
        ),
        $every,
        'bookmark pages hold every bookmark once, newest first, through ties'
    );
    is(
        _order_by( $store->bookmarks_resultset( $user, { limit => 1 } ) ),
        'created_at DESC, bookmark_id DESC',
        'bookmark pages break a tie on created_at by the id'
    );
    _assert_page_edge(
        sub {
            my ($limit) = @_;
            return $store->list_page_for_user( $user, { limit => $limit } );
        },
        scalar @{$every},
        'bookmark page'
    );

    return;
}

# ADR 0102: a bookmark on a thread the reader cannot read is left out in the
# query, before LIMIT, so the page is still full.
sub _bookmark_readability {
    my ($ctx) = @_;

    my $user = $ctx->{users}{erin};
    my %at   = (
        $EARLY  => _thread($ctx),
        $MIDDLE => _thread($ctx),
        $LATE   => $ctx->{private_thread},
    );
    my $store = _bookmarks($ctx);
    for my $when ( sort keys %at ) {
        $ctx->{clock}->iso8601($when);
        $store->save_bookmark(
            {
                target_id   => $at{$when},
                target_type => 'thread',
                user_id     => $user
            }
        );
    }
    $ctx->{clock}->iso8601($NOW);

    my %options = ( limit => $PAGE_LIMIT, target_type => 'thread' );
    is_deeply(
        _ids(
            $store->list_page_for_user( $user, {%options} )->{items},
            'target_id'
        ),
        [ @at{ $LATE, $MIDDLE } ],
        'unfiltered, the private thread\'s bookmark leads the page'
    );
    is_deeply(
        _ids(
            _bookmarks( $ctx, readability => _readability($ctx) )
              ->list_page_for_user( $user, {%options} )->{items},
            'target_id'
        ),
        [ @at{ $MIDDLE, $EARLY } ],
        'a bookmark on a thread the member cannot read is left out,'
          . ' and the page is still full'
    );

    return;
}

sub _mention_recording {
    my ($ctx) = @_;

    my $store = _mention_store($ctx);
    my $post  = _post($ctx);
    my $alice = $ctx->{users}{alice};
    my $body  = 'Grazie @Alice, ancora @alice e @ghost; scrivi a a@b.it';
    my $recorded =
      $store->record_for_source( _mention_input( $ctx, $post, $body ) );
    ok( $recorded->{ok}, 'mention recording succeeds' );
    is( scalar @{ $recorded->{created} },
        1, 'mention recording creates resolved users only, once each' );
    is( $recorded->{created}[0]{mentioned_user_id},
        $alice, 'mention stores resolved user id' );
    is( $recorded->{created}[0]{mentioned_username},
        'alice', 'mention stores normalized username' );
    is( scalar @{ $recorded->{skipped} },
        1, 'mention recording reports skipped unresolved users' );
    is( $recorded->{skipped}[0]{reason},
        'unknown_user', 'unknown mention skip reason is explicit' );
    my $row =
      _row( $ctx, $MENTION_ROW_SQL, $recorded->{created}[0]{mention_id} );
    is_deeply(
        [
            @{$row}{qw(source_id actor_id mentioned_user_id mentioned_username)}
        ],
        [ $post, $ctx->{users}{giacomo}, $alice, 'alice' ],
        'mention row is inserted'
    );

    my $notified = $recorded->{notifications};
    is( scalar @{$notified},
        1, 'mention recording creates mention notification' );
    is( $notified->[0]{notification}{recipient_user_id},
        $alice, 'mention notification targets mentioned user' );
    is( $notified->[0]{notification}{notification_type},
        'mention', 'mention notification has explicit type' );
    is( $notified->[0]{notification}{payload}{post_id},
        $post, 'mention notification links source post' );
    is( _value( $ctx, $NOTIFICATIONS_SQL, $alice, $post ),
        1, 'mention notification is stored for the mentioned member' );

    _mention_recorded_again( $ctx, $store, $post );

    return;
}

sub _mention_recorded_again {
    my ( $ctx, $store, $post ) = @_;

    my $alice = $ctx->{users}{alice};
    my $again =
      $store->record_for_source( _mention_input( $ctx, $post, '@alice' ) );
    is( scalar @{ $again->{created} },
        0, 'duplicate mention recording is idempotent' );
    is( scalar @{ $again->{skipped} },
        0, 'duplicate mentions do not report user-facing skips' );
    is( scalar @{ $again->{notifications} },
        0, 'duplicate mention creates no notification' );
    is( _value( $ctx, $SOURCE_MENTIONS_SQL, $post, $alice ),
        1, 'duplicate mention does not add rows' );
    is( _value( $ctx, $NOTIFICATIONS_SQL, $alice, $post ),
        1, 'nor a second notification' );

    return;
}

# The same post is recorded by a concurrent request, which commits the
# mention and its notification between this store's look-up and its insert.
sub _mention_race {
    my ($ctx) = @_;

    my $post  = _post($ctx);
    my $alice = $ctx->{users}{alice};
    my $input = _mention_input( $ctx, $post, '@alice' );
    my $raced = _racing(
        $ctx,
        'mentions',
        sub {
            my ($rival) = @_;
            _mention_store( $ctx, schema => $rival )->record_for_source($input);
            return;
        },
        sub { return _mention_store($ctx)->record_for_source($input); }
    );
    is( scalar @{ $raced->{created} },
        0, 'unique mention race does not create a second row' );
    is( scalar @{ $raced->{skipped} },
        0, 'unique mention race does not report a user-facing skip' );
    is( scalar @{ $raced->{notifications} },
        0, 'unique mention race creates no notification' );
    is( _value( $ctx, $SOURCE_MENTIONS_SQL, $post, $alice ),
        1, 'unique mention race does not add rows' );
    is( _value( $ctx, $NOTIFICATIONS_SQL, $alice, $post ),
        1, 'unique mention race leaves the one notification' );

    return;
}

sub _mention_id_collision {
    my ($ctx) = @_;

    my $taken = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $MENTION_SQL, undef, $taken, _post($ctx),
        @{ $ctx->{users} }{qw(bob carol)},
        'carol', $NOW );
    my $post = _post($ctx);
    my $recorded =
      _mention_store( $ctx,
        id_service => GPForum::Test::ScriptedId->new( next_ids => [$taken] ) )
      ->record_for_source( _mention_input( $ctx, $post, '@alice' ) );
    is( scalar @{ $recorded->{created} },
        1, 'unique mention id collision remints and records' );
    my $created = $recorded->{created}[0] // {};
    ok(
        GPForum::Infrastructure::Id->is_uuid( $created->{mention_id} )
          && $created->{mention_id} ne $taken,
        'unique mention id collision remints the id'
    );
    is(
        $created->{mentioned_user_id},
        $ctx->{users}{alice},
        'unique mention id collision keeps this mentioned user'
    );
    is( $created->{source_id}, $post,
        'unique mention id collision keeps this source' );

    return;
}

# The rival commits this very mention, under the id the store is about to
# use, but not its notification: the store reuses the mention and sends the
# notification that is missing.
sub _mention_id_race {
    my ($ctx) = @_;

    my $id       = $ctx->{ids}->uuid;
    my $post     = _post($ctx);
    my $alice    = $ctx->{users}{alice};
    my $recorded = _racing(
        $ctx,
        'mentions',
        sub {
            my ($rival) = @_;
            $rival->storage->dbh->do( $MENTION_SQL, undef, $id, $post,
                $ctx->{users}{giacomo},
                $alice, 'alice', $NOW );
            return;
        },
        sub {
            return _mention_store( $ctx,
                id_service =>
                  GPForum::Test::ScriptedId->new( next_ids => [$id] ) )
              ->record_for_source( _mention_input( $ctx, $post, '@alice' ) );
        }
    );
    is( scalar @{ $recorded->{created} },
        0, 'leftover mention id race reuses this mention' );
    my $row = _row( $ctx, $MENTION_ROW_SQL, $id );
    is( $row->{source_id}, $post,
        'leftover mention id race keeps this mention' );
    is( $row->{mentioned_user_id},
        $alice, 'leftover mention id race keeps this mentioned user' );
    is( _value( $ctx, $SOURCE_MENTIONS_SQL, $post, $alice ),
        1, 'leftover mention id race does not insert a second mention' );
    is( scalar @{ $recorded->{notifications} },
        1, 'leftover mention id race inserts the missing notification' );
    is( _value( $ctx, $NOTIFICATIONS_SQL, $alice, $post ),
        1, 'leftover mention id race stores that notification' );

    return;
}

sub _self_mention {
    my ($ctx) = @_;

    my $post = _post($ctx);
    my $self = _mention_store($ctx)
      ->record_for_source( _mention_input( $ctx, $post, '@giacomo' ) );
    is( scalar @{ $self->{created} }, 0, 'self mention does not create rows' );
    is( $self->{skipped}[0]{reason},
        'self_mention', 'self mention skip reason is explicit' );
    is( _value( $ctx, $SOURCE_ALL_MENTIONS_SQL, $post ),
        0, 'self mention does not add mention rows' );

    return;
}

# Alice's mentions all carry the fixed clock's instant, so the pages run
# through ties; each page joins the actor, whose users row has a created_at
# too, so an unqualified keyset column would be ambiguous on PostgreSQL.
sub _mention_pages {
    my ($ctx) = @_;

    my $alice  = $ctx->{users}{alice};
    my $reader = GPForum::Service::Community::MentionReader->new(
        schema => $ctx->{schema} );
    my $page =
      $reader->list_page_for_recipient( $alice, { limit => $LIST_LIMIT } );
    my $every =
      $ctx->{dbh}->selectcol_arrayref( $RECIPIENT_MENTIONS_SQL, undef, $alice );
    cmp_ok( scalar @{$every},
        q{>}, $PAGE_LIMIT, 'alice has mentions to page through' );
    is_deeply( _ids( $page->{items}, 'mention_id' ),
        $every, 'mention reader returns the recipient\'s mentions only' );
    is( $page->{items}[0]->get_column('actor_username'),
        'giacomo', 'mention reader joins the actor' );
    is_deeply(
        _walk(
            sub {
                my ($after) = @_;
                return $reader->list_page_for_recipient( $alice,
                    { after => $after, limit => 1 } );
            },
            'mention_id'
        ),
        $every,
        'mention pages hold every mention once, through ties on created_at'
    );
    is(
        _order_by( $reader->mentions_resultset( $alice, { limit => 1 } ) ),
        'created_at DESC, mention_id DESC',
        'mention pages break a tie on created_at by the id'
    );
    _assert_page_edge(
        sub {
            my ($limit) = @_;
            return $reader->list_page_for_recipient( $alice,
                { limit => $limit } );
        },
        scalar @{$every},
        'mention page'
    );
    unlike(
        ${
            $reader->mentions_resultset( $alice, { limit => $PAGE_LIMIT } )
              ->as_query
        }->[0],
        qr/\b OFFSET \b/imsx,
        'mention reader does not use offset'
    );

    return;
}

# ADR 0102: a mention of someone who cannot read the source is not
# recorded, and a mention whose source they can no longer read is left out of
# their page before LIMIT.
sub _mention_readability {
    my ($ctx) = @_;

    my $alice   = $ctx->{users}{alice};
    my $guarded = _mention_store( $ctx, readability => _readability($ctx) );
    my $hidden  = $guarded->record_for_source(
        _mention_input( $ctx, $ctx->{private_post}, '@alice' ) );
    is_deeply( [ map { $_->{reason} } @{ $hidden->{skipped} } ],
        ['source_not_readable'],
        'a mention of someone who cannot read the post is not recorded' );
    is( _value( $ctx, $SOURCE_MENTIONS_SQL, $ctx->{private_post}, $alice ),
        0, 'and leaves no row' );
    my $open = _post($ctx);
    is(
        scalar @{
            $guarded->record_for_source(
                _mention_input( $ctx, $open, '@alice' )
            )->{created}
        },
        1,
        'a mention on a post they can read is'
    );

    $ctx->{dbh}
      ->do( $MENTION_SQL, undef, $ctx->{ids}->uuid, $ctx->{private_post},
        $ctx->{users}{giacomo},
        $alice, 'alice', $LATER );
    my $unfiltered =
      GPForum::Service::Community::MentionReader->new(
        schema => $ctx->{schema} )
      ->list_page_for_recipient( $alice, { limit => $PAGE_LIMIT } );
    is( $unfiltered->{items}[0]->get_column('source_id'),
        $ctx->{private_post},
        'unfiltered, the mention on the private post leads the page' );
    my $filtered = GPForum::Service::Community::MentionReader->new(
        readability => _readability($ctx),
        schema      => $ctx->{schema},
    )->list_page_for_recipient( $alice, { limit => $PAGE_LIMIT } );
    is( scalar @{ $filtered->{items} },
        $PAGE_LIMIT, 'filtered, the page is still full' );
    ok(
        !(
            grep { $_->get_column('source_id') eq $ctx->{private_post} }
            @{ $filtered->{items} }
        ),
        'without the mention on a post the member cannot read'
    );

    return;
}

sub _reputation_ledger {
    my ($ctx) = @_;

    my $user   = $ctx->{users}{giacomo};
    my $ledger = _ledger($ctx);
    my $first  = $ledger->record_event(
        {
            %{ _reputation_input( $ctx, $user, _post($ctx) ) },
            current_score => $DECLARED_SCORE,
        }
    );
    ok( $first->{ok}, 'reputation event succeeds' );
    my $event_id = $first->{event}{reputation_event_id};
    ok( GPForum::Infrastructure::Id->is_uuid($event_id),
        'reputation event id is generated' );
    is( $first->{event}{delta}, $DELTA, 'reputation event stores delta' );
    is( $first->{snapshot}{score},
        $FIRST_SCORE, 'trust snapshot stores calculated score' );
    is( $first->{snapshot}{trust_level},
        $TRUST_LEVEL, 'trust snapshot stores trust level' );
    is( $first->{snapshot}{version}, 1, 'trust snapshot stores version' );
    is( _value( $ctx, $USER_EVENTS_SQL, $user ),
        1, 'reputation event row is inserted' );
    is( _value( $ctx, $SCORE_SQL, $user ),
        $FIRST_SCORE, 'trust snapshot row is upserted' );
    is( _value( $ctx, $TRUST_SQL, $user ),
        $TRUST_LEVEL, 'ledger syncs the user trust level' );
    _reputation_follow_on( $ctx, $ledger, $user );

    return;
}

# The event and the snapshot commit together, or neither does: a snapshot
# PostgreSQL refuses, its score past the integer range, leaves no event
# crediting a delta the score never received. The event has to have gone in
# before the snapshot failed, or its absence afterwards proves nothing: a
# ledger that wrote the snapshot first would pass without a transaction.
sub _reputation_atomic {
    my ($ctx) = @_;

    my $user  = $ctx->{users}{carol};
    my $input = _reputation_input( $ctx, $user, _post($ctx) );
    my @sent;
    my $recorded = eval {
        _traced(
            $ctx,
            sub {
                my ($statement) = @_;
                push @sent, $statement;
                return;
            },
            sub {
                return _ledger($ctx)
                  ->record_event(
                    { %{$input}, current_score => $INTEGER_MAX } );
            }
        );
        1;
    };
    ok( !$recorded, 'a snapshot PostgreSQL refuses fails the event' );
    my ($event) =
      grep { $sent[$_] =~ /\A INSERT [ ] INTO [ ] reputation_events [ ]/msx }
      0 .. $#sent;
    my ($snapshot) =
      grep {
        $sent[$_] =~ /\A INSERT [ ] INTO [ ] trust_score_snapshots [ ]/msx
      } 0 .. $#sent;
    ok( defined $event && defined $snapshot && $event < $snapshot,
        'after the event was inserted' );
    is(
        _value( $ctx, $SOURCE_EVENTS_SQL, $user, $input->{source_id} ),
        0,
        'reputation ledger writes the event and the snapshot in one transaction'
    );
    is( _value( $ctx, $SNAPSHOTS_SQL, $user ), 0, 'and leaves no snapshot' );

    return;
}

sub _reputation_follow_on {
    my ( $ctx, $ledger, $user ) = @_;

    my $user_version = _version( $ctx, user => $user );
    my $input        = _reputation_input( $ctx, $user, _post($ctx) );
    my ( $follow_on, $statements ) =
      _statements( $ctx, sub { return $ledger->record_event($input) } );
    ok( $follow_on->{ok}, 'follow-on reputation event succeeds' );
    is( $follow_on->{snapshot}{score},
        $FOLLOW_ON_SCORE, 'ledger continues from the stored snapshot score' );
    is( _value( $ctx, $SCORE_SQL, $user ), $FOLLOW_ON_SCORE, 'and stores it' );
    is( _value( $ctx, $USER_EVENTS_SQL, $user ),
        $FOLLOW_ON_ROWS, 'follow-on reputation event inserts another row' );
    is( _version( $ctx, user => $user ),
        $user_version, 'unchanged trust level does not restamp the user' );
    my ($locked) = grep {
        $statements->[$_] =~
/\A SELECT [ ] .* FROM [ ] trust_score_snapshots [ ] .* FOR [ ] UPDATE/msx
    } 0 .. $#{$statements};
    my ($written) =
      grep { $statements->[$_] =~ /\A UPDATE [ ] trust_score_snapshots [ ]/msx }
      0 .. $#{$statements};
    ok(
        defined $locked && defined $written && $locked < $written,
        'reputation ledger locks the snapshot row before read-modify-writing it'
    );

    my $replayed = $ledger->record_event($input);
    ok( $replayed->{skipped}, 'duplicate source reputation event is skipped' );
    is( $replayed->{snapshot}{score},
        $FOLLOW_ON_SCORE,
        'replayed reputation keeps the stored snapshot score' );
    is( _value( $ctx, $USER_EVENTS_SQL, $user ),
        $FOLLOW_ON_ROWS, 'replayed reputation does not insert another row' );

    my $missing = $ledger->record_event(
        {
            actor_id    => $ctx->{users}{moderator},
            delta       => $DELTA,
            reason      => 'helpful_post',
            source_type => 'post',
            user_id     => $user,
        }
    );
    ok( $missing->{skipped}, 'reputation without source_id is skipped' );
    is( $missing->{reason}, 'missing_source',
        'reputation names a missing source_id' );
    is( _value( $ctx, $USER_EVENTS_SQL, $user ),
        $FOLLOW_ON_ROWS, 'reputation without source_id does not insert a row' );

    return;
}

# A concurrent worker records the same event, delta and snapshot included,
# between this ledger's look-up and its insert: the delta counts once.
sub _reputation_race {
    my ($ctx) = @_;

    my $user  = $ctx->{users}{giacomo};
    my $input = _reputation_input( $ctx, $user, _post($ctx) );
    my $raced = _racing(
        $ctx,
        'reputation_events',
        sub {
            my ($rival) = @_;
            _ledger( $ctx, schema => $rival )->record_event($input);
            return;
        },
        sub { return _ledger($ctx)->record_event($input); }
    );
    ok( $raced->{skipped}, 'reputation unique race replays the stored event' );
    is( $raced->{snapshot}{score},
        $RACED_SCORE, 'reputation unique race counts the delta once' );
    is( _value( $ctx, $SCORE_SQL, $user ),
        $RACED_SCORE, 'reputation unique race keeps the stored snapshot' );
    is( _value( $ctx, $SOURCE_EVENTS_SQL, $user, $input->{source_id} ),
        1, 'reputation unique race does not insert another row' );
    is( _value( $ctx, $USER_EVENTS_SQL, $user ),
        $RACED_ROWS, 'beside the rival\'s own' );

    return;
}

sub _reputation_id_collision {
    my ($ctx) = @_;

    my $taken = $ctx->{ids}->uuid;
    $ctx->{dbh}->do(
        $EVENT_SQL, undef, $taken,
        $ctx->{users}{erin},
        $ctx->{users}{moderator},
        _post($ctx), 1
    );
    my $user = $ctx->{users}{bob};
    my $recorded =
      _ledger( $ctx,
        id_service => GPForum::Test::ScriptedId->new( next_ids => [$taken] ) )
      ->record_event(
        {
            %{ _reputation_input( $ctx, $user, _post($ctx) ) },
            current_score => $DECLARED_SCORE,
        }
      );
    ok( $recorded->{ok}, 'unique reputation id collision remints and records' );
    ok( !$recorded->{skipped},
        'unique reputation id collision does not replay another event' );
    my $id = $recorded->{event}{reputation_event_id};
    ok(
        GPForum::Infrastructure::Id->is_uuid($id) && $id ne $taken,
        'unique reputation id collision remints the id'
    );
    is( $recorded->{event}{user_id},
        $user, 'unique reputation id collision keeps this user' );
    is(
        _value( $ctx, $EVENT_USER_SQL, $taken ),
        $ctx->{users}{erin},
        'and leaves the other event alone'
    );

    return;
}

# The rival commits this very event, under the id the ledger is about to
# use, but no snapshot: the ledger reuses the event and writes the snapshot
# that is missing.
sub _reputation_id_race {
    my ($ctx) = @_;

    my $id       = $ctx->{ids}->uuid;
    my $user     = $ctx->{users}{dave};
    my $input    = _reputation_input( $ctx, $user, _post($ctx) );
    my $recorded = _racing(
        $ctx,
        'reputation_events',
        sub {
            my ($rival) = @_;
            $rival->storage->dbh->do( $EVENT_SQL, undef, $id, $user,
                @{$input}{qw(actor_id source_id delta)} );
            return;
        },
        sub {
            return _ledger( $ctx,
                id_service =>
                  GPForum::Test::ScriptedId->new( next_ids => [$id] ) )
              ->record_event( { %{$input}, current_score => $DECLARED_SCORE } );
        }
    );
    ok( $recorded->{skipped}, 'leftover reputation id race reuses this event' );
    is( $recorded->{event}{reputation_event_id},
        $id, 'leftover reputation id race keeps this event' );
    is( $recorded->{snapshot}{score},
        $FIRST_SCORE,
        'leftover reputation id race inserts the missing snapshot' );
    is( _value( $ctx, $SCORE_SQL, $user ),
        $FIRST_SCORE, 'leftover reputation id race stores that snapshot' );
    is( _value( $ctx, $USER_EVENTS_SQL, $user ),
        1, 'leftover reputation id race does not insert a second event' );

    return;
}

# A concurrent first event for the same member commits its snapshot between
# this ledger's look-up and its insert: the delta goes onto that row.
sub _snapshot_race {
    my ($ctx) = @_;

    my $user  = $ctx->{users}{alice};
    my $raced = _racing(
        $ctx,
        'trust_score_snapshots',
        sub {
            my ($rival) = @_;
            $rival->storage->dbh->do( $SNAPSHOT_SQL, undef, $user,
                $SEED_SCORE );
            return;
        },
        sub {
            return _ledger($ctx)
              ->record_event( _reputation_input( $ctx, $user, _post($ctx) ) );
        }
    );
    ok( $raced->{ok}, 'unique trust snapshot race applies the delta' );
    is( $raced->{snapshot}{score},
        $SEED_RACE_SCORE,
        'unique trust snapshot race adds the delta to the winning row' );
    is( _value( $ctx, $SNAPSHOTS_SQL, $user ),
        1, 'unique trust snapshot race does not insert a second snapshot' );
    is( _value( $ctx, $SCORE_SQL, $user ),
        $SEED_RACE_SCORE,
        'unique trust snapshot race updates the winning snapshot' );

    return;
}

sub _feed_projection {
    my ($ctx) = @_;

    my $projector = _projector($ctx);
    my @readers   = @{ $ctx->{users} }{qw(giacomo alice bob)};
    my $post      = _post($ctx);
    my ( $projected, $inserts ) = _feed_inserts(
        $ctx,
        sub {
            return $projector->project_item(
                {
                    created_at => $NOW,
                    item_id    => $post,
                    item_type  => 'post',
                    user_ids   => [ @readers, $readers[0] ],
                }
            );
        }
    );
    is_deeply(
        [ @{$projected}{qw(projected written)} ],
        [ $RECIPIENTS, $RECIPIENTS ],
        'feed projection reaches each recipient once'
    );
    is( $inserts, 1, 'in one statement' );
    is( _value( $ctx, $FEED_ROWS_SQL, 'post', $post ),
        $RECIPIENTS, 'one feed row per recipient' );

    my $withdrawn =
      $projector->remove_item( { item_id => $post, item_type => 'post' } );
    ok( $withdrawn->{ok}, 'feed removal succeeds' );
    is( $withdrawn->{removed}, $RECIPIENTS,
        'feed removal deletes every projected user row' );
    is( _value( $ctx, $FEED_ROWS_SQL, 'post', $post ),
        0, 'feed item rows are deleted' );

    return;
}

# Several items at the same instant, projected in ascending id order, a
# thread among the posts, and an item for someone else.
sub _feed_pages {
    my ($ctx) = @_;

    my $projector = _projector($ctx);
    my $user      = $ctx->{users}{carol};
    my @tied      = sort map { _post($ctx) } 1 .. $TIED;
    my @items     = (
        [ $EARLY,  post   => _post($ctx) ],
        [ $MIDDLE, thread => _thread($ctx) ],
        [ $LATE,   post   => _post($ctx) ],
        map { [ $NOW, post => $_ ] } @tied,
    );
    for my $item (@items) {
        my ( $at, $type, $id ) = @{$item};
        $projector->project_item(
            {
                created_at => $at,
                item_id    => $id,
                item_type  => $type,
                user_ids   => [ $user, $ctx->{users}{dave} ],
            }
        );
    }
    my $moderated = $items[2][2];
    my $elsewhere = _post($ctx);
    $projector->project_item(
        {
            created_at => $LATER,
            item_id    => $elsewhere,
            item_type  => 'post',
            user_ids   => [ $ctx->{users}{dave} ],
        }
    );

    my $reader =
      GPForum::Service::Community::FeedReader->new( schema => $ctx->{schema} );
    my $every = $ctx->{dbh}->selectcol_arrayref( $USER_FEED_SQL, undef, $user );
    my $first = $reader->list_page_for_user( $user, { limit => $LIST_LIMIT } );
    is_deeply( _ids( $first->{items}, 'item_id' ),
        $every, 'feed reader returns the member\'s rows only' );
    ok(
        !( grep { $_ eq $elsewhere } @{ _ids( $first->{items}, 'item_id' ) } ),
        'feed reader filters user'
    );
    is_deeply(
        _walk(
            sub {
                my ($after) = @_;
                return $reader->list_page_for_user( $user,
                    { after => $after, limit => 1 } );
            },
            'item_id'
        ),
        $every,
        'feed pages hold every item once, newest first, through ties'
    );
    is(
        _order_by( $reader->feed_resultset( $user, { limit => 1 } ) ),
        'created_at DESC, item_id DESC',
        'feed pages break a tie on created_at by the id'
    );
    _assert_page_edge(
        sub {
            my ($limit) = @_;
            return $reader->list_page_for_user( $user, { limit => $limit } );
        },
        scalar @{$every},
        'feed page'
    );
    unlike(
        ${
            $reader->feed_resultset( $user, { limit => $PAGE_LIMIT } )
              ->as_query
        }->[0],
        qr/\b OFFSET \b/imsx,
        'feed reader does not use offset'
    );

    $projector->remove_item( { item_id => $moderated, item_type => 'post' } );
    ok(
        !(
            grep { $_->get_column('item_id') eq $moderated } @{
                $reader->list_page_for_user( $user, { limit => $LIST_LIMIT } )
                  ->{items}
            }
        ),
        'feed reader hides removed moderated items'
    );

    return;
}

# ADR 0102: an item on a post the reader cannot read is left out in the
# query, before LIMIT.
sub _feed_readability {
    my ($ctx) = @_;

    my $projector = _projector($ctx);
    my $user      = $ctx->{users}{erin};
    my %at        = (
        $EARLY  => _post($ctx),
        $MIDDLE => _post($ctx),
        $LATE   => $ctx->{private_post},
    );
    for my $when ( sort keys %at ) {
        $projector->project_item(
            {
                created_at => $when,
                item_id    => $at{$when},
                item_type  => 'post',
                user_ids   => [$user],
            }
        );
    }

    my %options = ( limit => $PAGE_LIMIT );
    is_deeply(
        _ids(
            GPForum::Service::Community::FeedReader->new(
                schema => $ctx->{schema}
            )->list_page_for_user( $user, {%options} )->{items},
            'item_id'
        ),
        [ @at{ $LATE, $MIDDLE } ],
        'unfiltered, the private post leads the feed'
    );
    is_deeply(
        _ids(
            GPForum::Service::Community::FeedReader->new(
                readability => _readability($ctx),
                schema      => $ctx->{schema},
            )->list_page_for_user( $user, {%options} )->{items},
            'item_id'
        ),
        [ @at{ $MIDDLE, $EARLY } ],
        'a feed item on a post the member cannot read is left out,'
          . ' and the page is still full'
    );

    return;
}

sub _bookmarks {
    my ( $ctx, %options ) = @_;

    return GPForum::Service::Community::BookmarkStore->new(
        clock      => $ctx->{clock},
        id_service => $ctx->{ids},
        schema     => $ctx->{schema},
        %options,
    );
}

# The real dispatcher, on the store's own connection: a mention's
# notification is deduplicated against the rows PostgreSQL holds, not
# against a list in a double.
sub _mention_store {
    my ( $ctx, %options ) = @_;

    my $schema = $options{schema} // $ctx->{schema};

    return GPForum::Service::Community::MentionStore->new(
        clock                   => $ctx->{clock},
        id_service              => $ctx->{ids},
        notification_dispatcher =>
          GPForum::Service::Notification::Dispatcher->new(
            clock  => $ctx->{clock},
            schema => $schema
          ),
        schema => $schema,
        %options,
    );
}

sub _mention_input {
    my ( $ctx, $post, $body ) = @_;

    return {
        actor_id    => $ctx->{users}{giacomo},
        body_source => $body,
        source_id   => $post,
        source_type => 'post',
    };
}

sub _ledger {
    my ( $ctx, %options ) = @_;

    return GPForum::Service::Community::ReputationLedger->new(
        clock      => $ctx->{clock},
        id_service => $ctx->{ids},
        schema     => $ctx->{schema},
        %options,
    );
}

sub _reputation_input {
    my ( $ctx, $user, $post ) = @_;

    return {
        actor_id    => $ctx->{users}{moderator},
        delta       => $DELTA,
        reason      => 'helpful_post',
        source_id   => $post,
        source_type => 'post',
        user_id     => $user,
    };
}

sub _projector {
    my ($ctx) = @_;

    return GPForum::Service::Community::FeedProjector->new(
        schema => $ctx->{schema} );
}

sub _readability {
    my ($ctx) = @_;

    return GPForum::Service::Forum::Readability->new(
        schema => $ctx->{schema} );
}

sub _target_key {
    my ($target) = @_;

    return @{$target}{qw(user_id target_type target_id)};
}

# The page that holds every row has no cursor; one row short of that, the
# extra row it fetched says there is a next page.
sub _assert_page_edge {
    my ( $read, $rows, $label ) = @_;

    my $whole = $read->($rows);
    is( scalar @{ $whole->{items} }, $rows, "$label holds every row" );
    is( $whole->{next_cursor},       undef, "$label omits empty cursor" );
    my $short = $read->( $rows - 1 );
    is( scalar @{ $short->{items} }, $rows - 1, "$label applies limit" );
    ok( $short->{next_cursor},
        "$label fetches one extra keyset row and mints a cursor" );

    return;
}

# Every row of a keyset list, a page at a time.
sub _walk {
    my ( $read, $column ) = @_;

    my $page  = $read->(undef);
    my @ids   = @{ _ids( $page->{items}, $column ) };
    my $pages = 1;
    while ( $page->{next_cursor} && $pages < $MAX_PAGES ) {
        $page = $read->( $page->{next_cursor} );
        push @ids, @{ _ids( $page->{items}, $column ) };
        $pages++;
    }

    return \@ids;
}

sub _ids {
    my ( $rows, $column ) = @_;

    return [ map { $_->get_column($column) } @{$rows} ];
}

# The ORDER BY clause a resultset sends. A walk through ties shows the pages
# right under the plan PostgreSQL picked that time. Without the id in ORDER
# BY, a tie comes back in whatever order the plan meets its rows, and that
# can be the right one: the feed's index on (user_id, created_at DESC,
# item_id DESC) always hands them over so. Whether a walk noticed changed
# from run to run, so the clause is pinned as well. The me. qualifier is left
# out.
sub _order_by {
    my ($resultset) = @_;

    my ($sql)   = @{ ${ $resultset->as_query } };
    my ($order) = $sql =~ / [ ] ORDER [ ] BY [ ] (.+?) [ ] LIMIT [ ] /msx;
    $order //= q{};
    $order =~ s/\b me [.] //gmsx;

    return $order;
}

# Runs $code; just before its first INSERT INTO $table reaches PostgreSQL,
# $rival runs on the second connection and commits. That is the window a
# concurrent request has between a store's look-up and its insert.
sub _racing {
    my ( $ctx, $table, $rival, $code ) = @_;

    my $pending = 1;
    my $result  = _traced(
        $ctx,
        sub {
            my ($statement) = @_;
            if (   $pending
                && $statement =~ /\A INSERT [ ] INTO [ ] \Q$table\E [ ]/msx )
            {
                $pending = 0;
                $rival->( $ctx->{rival} );
            }
            return;
        },
        $code
    );
    ok( !$pending, "the rival committed before the $table insert" );

    return $result;
}

# The statements $code sends through DBIx::Class, in order.
sub _statements {
    my ( $ctx, $code ) = @_;

    my @sent;
    my $result = _traced(
        $ctx,
        sub {
            my ($statement) = @_;
            push @sent, $statement;
            return;
        },
        $code
    );

    return ( $result, \@sent );
}

sub _traced {
    my ( $ctx, $watch, $code ) = @_;

    my $storage = $ctx->{schema}->storage;
    $storage->debugcb(
        sub {
            my ( undef, $statement ) = @_;
            $watch->($statement);
            return;
        }
    );
    $storage->debug(1);
    my $result = eval { return $code->() };
    my $error  = $EVAL_ERROR;
    $storage->debug(0);
    $storage->debugcb(undef);
    croak $error if $error;

    return $result;
}

# The INSERT statements into user_feed_items $code sends. The projector
# writes through the database handle, below DBIx::Class, and DBD::Pg
# prepares every statement that carries bind values, a do included: counting
# the do as well counted each statement twice.
sub _feed_inserts {
    my ( $ctx, $code ) = @_;

    my $inserts = 0;
    my $count   = sub {
        my ( undef, $statement ) = @_;
        if ( $statement =~ /\A INSERT [ ] INTO [ ] user_feed_items [ ]/msx ) {
            $inserts++;
        }
        return;
    };
    $ctx->{dbh}->{Callbacks} =
      { map { $_ => $count } qw(prepare prepare_cached) };
    my $result = eval { return $code->() };
    my $error  = $EVAL_ERROR;
    delete $ctx->{dbh}->{Callbacks};
    croak $error if $error;

    return ( $result, $inserts );
}

sub _version {
    my ( $ctx, $table, $key ) = @_;

    return _value( $ctx, $VERSION_SQL{$table}, $key );
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
