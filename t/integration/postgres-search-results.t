# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::Viewer;
use GPForum::Service::Search::Indexer;
use GPForum::Service::Search::PermissionEngine;
use GPForum::Service::Search::Searcher;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the search results test';
}

# What search returns, on PostgreSQL (quality program 5.2). The unit double
# matches every document whatever the query, so ranking, the AND of the
# words, the tolerance for typos and the autocomplete prefix had no
# behavioural coverage at all. Three threads are given words of their own
# and indexed as the application indexes them.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );
is( $prepared->{seed},    0, 'the seed loads' );

my $schema  = GPForum::Test::PostgresHarness::connect_schema();
my $dbh     = $schema->storage->dbh;
my $indexer = GPForum::Service::Search::Indexer->new( schema => $schema );

my ( $vacuum, $bodies, $zymurgy ) = @{
    $dbh->selectcol_arrayref(
            q{SELECT thread_id FROM threads WHERE deleted_at IS NULL}
          . q{ AND visibility = 'public' AND moderation_state = 'visible'}
          . q{ ORDER BY thread_id LIMIT 3}
    )
};
_retitle( $vacuum,  'Tuning postgres vacuum' );
_retitle( $zymurgy, 'Zymurgy basics' );
my ($reply) = $dbh->selectrow_array(
    q{SELECT post_id FROM posts WHERE thread_id = ? AND position > 1}
      . q{ ORDER BY position LIMIT 1},
    undef, $bodies
);
$dbh->do(
    q{UPDATE post_bodies SET body_source = ?, body_rendered_safe = ?}
      . q{ WHERE body_id = (SELECT current_body_id FROM posts WHERE post_id = ?)},
    undef, ('An aside on zymurgy and the brewing of it') x 2, $reply
);
$indexer->index_post($reply);

my $searcher = GPForum::Service::Search::Searcher->new(
    permission_engine =>
      GPForum::Service::Search::PermissionEngine->new( schema => $schema ),
    schema => $schema,
);
my $anonymous = { viewer => GPForum::Service::Forum::Viewer->anonymous };

is_deeply( [ _threads_of( _search('vacuum') ) ],
    [$vacuum], 'a word in one title finds that thread and its posts only' );
is_deeply( [ _threads_of( _search('postgres vacuum') ) ],
    [$vacuum], 'two words find what holds both' );

# The fuzzy arm compares the whole query with each title, so a title that
# shares one word of two is found too -- by design (8.9), and ranked by its
# similarity. Nothing else is.
is_deeply(
    [ _threads_of( _search('postgres zymurgy') ) ],
    [ sort $vacuum, $zymurgy ],
    'two words that no document holds together find the titles close to them'
);
is_deeply( [ _threads_of( _search('vacum') ) ],
    [$vacuum], 'a typo still finds the title, by its trigrams' );

my @zymurgy = _search('zymurgy');
is( $zymurgy[0]{entity_id}, $zymurgy,
    'a title match ranks above a body match' );
ok( ( grep { $_->{entity_id} eq $reply } @zymurgy ),
    'and the body match is found' );
like( ( grep { $_->{entity_id} eq $reply } @zymurgy )[0]{snippet} // q{},
    qr/zymurgy/msx, 'with the word in its snippet' );

is_deeply( [ _search('unfindableword') ], [], 'no match finds nothing' );

is_deeply(
    [
        map { $_->{entity_id} } @{
            $searcher->autocomplete(
                $anonymous, 'tuning pos', { limit => 10 }
            )
        }
    ],
    [$vacuum],
    'autocomplete completes a title from its first letters'
);

# Filters reach SQL only well formed. from=garbage used to be bound as a
# timestamp as it came: PostgreSQL refused it, the page degraded, and the log
# line quoted what the visitor had typed. A malformed filter is now no
# filter.
my @everything = _ids( _search('zymurgy') );
is_deeply(
    [
        _ids(
            _search(
                'zymurgy',
                {
                    author_user_id => q{1' OR '1'='1},
                    category_id    => 'not-a-category',
                    from           => 'garbage',
                    to             => '2026-02-30',
                }
            )
        )
    ],
    \@everything,
    'malformed filters are ignored, not sent to the database'
);

# A time whose offset RFC 3339 does not allow: Mojo::Date read a hundred
# billion hours, and the instant it named was past a timestamp's range.
is_deeply(
    [
        _ids(
            _search(
                'zymurgy', { from => '2026-05-01T10:00:00-99999999999:00' }
            )
        )
    ],
    \@everything,
    'and so is a time whose offset is past the range of a timestamp'
);

# A day given as the upper bound covers that day. It was compared with the
# day's first instant, so to=<the day a reply was written> left the reply out.
my ($reply_day) = $dbh->selectrow_array(
    q{SELECT to_char(source_created_at, 'YYYY-MM-DD') FROM search_documents}
      . q{ WHERE entity_type = 'post' AND entity_id = ?},
    undef, $reply
);
ok(
    (
        grep { $_ eq $reply } _ids(
            _search( 'zymurgy', { from => $reply_day, to => $reply_day } )
        )
    ),
    'a search bounded by one day finds what was written that day'
);

# A time with no offset is read in the session's time zone, as a day is: it
# was bound as UTC, nine hours after the reply here. And to the microsecond:
# from and to at the reply's own instant find it only when both are exact.
$dbh->do(q{SET TIME ZONE 'Asia/Tokyo'});
my ($reply_local) = $dbh->selectrow_array(
    q{SELECT to_char(source_created_at, 'YYYY-MM-DD"T"HH24:MI:SS.US')}
      . q{ FROM search_documents WHERE entity_type = 'post' AND entity_id = ?},
    undef, $reply
);
ok(
    (
        grep { $_ eq $reply } _ids(
            _search( 'zymurgy', { from => $reply_local, to => $reply_local } )
        )
    ),
    'a time with no offset names its instant in the session time zone'
);
$dbh->do('RESET TIME ZONE');

# ADR 0102's window for a moved thread. A document keeps the category it was
# indexed under until the outbox reindexes it -- a thread's posts a batch per
# message -- and search judged it by that category: a thread moved from a
# public category into a private one stayed readable through search, to
# anyone, until its batch ran. Nothing is reindexed here.
my ($bodies_title) =
  $dbh->selectrow_array( 'SELECT title FROM threads WHERE thread_id = ?',
    undef, $bodies );
my ($private) = $dbh->selectrow_array(
    q{INSERT INTO categories (category_id, space_id, slug, title, visibility)}
      . q{ SELECT gen_random_uuid(), space_id, 'staff-room', 'Staff room',}
      . q{ 'private' FROM categories WHERE category_id =}
      . q{ (SELECT category_id FROM threads WHERE thread_id = ?)}
      . q{ RETURNING category_id},
    undef, $bodies
);
my ($public) =
  $dbh->selectrow_array( 'SELECT category_id FROM threads WHERE thread_id = ?',
    undef, $bodies );
my $staff = {
    viewer => GPForum::Service::Forum::Viewer->new(
        category_ids => [$private],
        member       => 1,
        user_id      => $dbh->selectrow_array('SELECT id FROM users LIMIT 1'),
    )
};

ok(
    _found( $anonymous, $bodies_title, $bodies ),
    'before the move, its thread is found'
);
ok( _found( $anonymous, 'zymurgy', $reply ),          'and its reply' );
ok( _suggested( $anonymous, $bodies_title, $bodies ), 'and suggested' );

_move( $bodies, $private );
ok( !_found( $anonymous, $bodies_title, $bodies ),
    'a thread moved into a private category is not found before its reindex' );
ok( !_found( $anonymous, 'zymurgy', $reply ),          'nor is its reply' );
ok( !_suggested( $anonymous, $bodies_title, $bodies ), 'nor suggested' );
ok( !_found( $staff, 'zymurgy', $reply ),
    'a reader of the new category waits for the reindex too' );

_move( $bodies, $public );
ok( _found( $anonymous, 'zymurgy', $reply ),
    'moved back before any reindex, the reply is found again' );

_move( $bodies, $private );
$indexer->index_thread($bodies);
$indexer->index_thread_posts($bodies);
ok( !_found( $anonymous, 'zymurgy', $reply ),
    'reindexed under the private category, it stays hidden from anonymous' );
ok( _found( $staff, 'zymurgy', $reply ), 'and its readers find it' );

# The same window for a category moved into another space. A document keeps
# the space it was indexed under, and the permission condition reads the
# space's visibility through it: without the space check, a category moved
# into a private space left its threads readable through search, by the
# public space they were indexed in. Nothing is reindexed here either.
my ($vacuum_category) =
  $dbh->selectrow_array( 'SELECT category_id FROM threads WHERE thread_id = ?',
    undef, $vacuum );
my ($public_space) = $dbh->selectrow_array(
    'SELECT space_id FROM categories WHERE category_id = ?',
    undef, $vacuum_category );
my ($private_space) = $dbh->selectrow_array(
        q{INSERT INTO spaces (space_id, slug, title, visibility)}
      . q{ VALUES (gen_random_uuid(), 'staff-space', 'Staff space', 'private')}
      . q{ RETURNING space_id} );

ok( _found( $anonymous, 'vacuum', $vacuum ),
    'before its category changes space, a thread is found' );
_move_category( $vacuum_category, $private_space );
ok(
    !_found( $anonymous, 'vacuum', $vacuum ),
    'a category moved into a private space hides its threads before their'
      . ' reindex'
);
ok( !_suggested( $anonymous, 'tuning pos', $vacuum ), 'and their titles' );
_move_category( $vacuum_category, $public_space );
ok( _found( $anonymous, 'vacuum', $vacuum ), 'moved back, it is found again' );

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _retitle {
    my ( $thread_id, $title ) = @_;

    $dbh->do( 'UPDATE threads SET title = ? WHERE thread_id = ?',
        undef, $title, $thread_id );
    $indexer->index_thread($thread_id);
    $indexer->index_thread_posts($thread_id);

    return;
}

sub _search {
    my ( $query, $filters ) = @_;

    return @{
        $searcher->search( $anonymous, $query,
            { %{ $filters || {} }, limit => 50 } )
    };
}

sub _ids {
    my (@results) = @_;

    my @ids = sort map { $_->{entity_id} } @results;

    return @ids;
}

sub _found {
    my ( $actor, $query, $entity_id ) = @_;

    return
      grep { $_->{entity_id} eq $entity_id }
      @{ $searcher->search( $actor, $query, { limit => 50 } ) };
}

sub _suggested {
    my ( $actor, $title, $thread_id ) = @_;

    return
      grep { $_->{entity_id} eq $thread_id }
      @{ $searcher->autocomplete( $actor, $title, { limit => 50 } ) };
}

# The thread row only, as the move's transaction leaves it: its documents
# wait for the outbox.
sub _move {
    my ( $thread_id, $category_id ) = @_;

    $dbh->do( 'UPDATE threads SET category_id = ? WHERE thread_id = ?',
        undef, $category_id, $thread_id );

    return;
}

# The category row only: its threads' documents keep the space they were
# indexed in.
sub _move_category {
    my ( $category_id, $space_id ) = @_;

    $dbh->do( 'UPDATE categories SET space_id = ? WHERE category_id = ?',
        undef, $space_id, $category_id );

    return;
}

# The distinct threads the results belong to: a thread's own document, or
# its posts'.
sub _threads_of {
    my (@results) = @_;

    my %thread;
    for my $result (@results) {
        my $id =
            $result->{entity_type} eq 'thread'
          ? $result->{entity_id}
          : scalar $dbh->selectrow_array(
            'SELECT thread_id FROM posts WHERE post_id = ?',
            undef, $result->{entity_id} );
        $thread{$id} = 1;
    }

    my @threads = sort keys %thread;

    return @threads;
}

1;
