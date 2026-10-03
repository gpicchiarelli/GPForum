# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

# A thread list's page size, which the category index's key used to name.
const my $HTTP_OK                => 200;
const my $HTTP_MOVED_PERMANENTLY => 301;
const my $THREAD_PAGE_SIZE       => 25;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the public cache test';
}

# The public page cache (8.2), against the application: its key named the
# raw query string and nothing of the visitor, so an English visitor was
# served the Italian page a previous visitor had cached, and every junk
# parameter minted an entry. And a hit was looked up after the page's
# queries had run.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );
is( $prepared->{seed},    0, 'the seed loads' );

# More public categories than a thread list's page, for the index below.
GPForum::Test::PostgresHarness::connect_schema()->storage->dbh->do(<<'SQL');
INSERT INTO categories (category_id, space_id, slug, title, position)
SELECT gen_random_uuid(), public_space.space_id, 'extra-' || n, 'Extra ' || n,
       1000 + n
FROM (
    SELECT categories.space_id
    FROM categories
    JOIN spaces ON spaces.space_id = categories.space_id
    WHERE categories.visibility = 'public'
      AND spaces.visibility = 'public'
      AND categories.deleted_at IS NULL
    LIMIT 1
) AS public_space, generate_series(1, 30) AS n
SQL

my $client = Test::Mojo->new('GPForum');

_get( '/categories', 'it' );
is( _state(),      'miss', 'an Italian visitor fills the cache' );
is( _html('lang'), 'it',   'with the Italian page' );
_get( '/categories', 'en' );
is( _html('lang'), 'en',   'an English visitor gets the English page' );
is( _state(),      'miss', 'from an entry of its own' );
_get( '/categories', 'en' );
is( _state(), 'hit', 'which the next English visitor is served' );
my $headers = $client->tx->res->headers;
like( $headers->vary // q{},
    qr/Accept-Language/msx, 'and caches downstream are told it varies' );

_get( '/categories?junk=1&more=junk', 'en' );
is( _state(), 'hit', 'a junk parameter does not mint an entry' );

# The index lists up to 100 categories unless asked for fewer, but its key
# named a thread list's page size, 25, when no limit was asked: a visitor who
# asked for 25 was served the full index, or filled the entry with 25 that
# every other visitor was then served.
my $full_index = _listed_categories();
ok( $full_index > $THREAD_PAGE_SIZE, 'the index lists every category' );
_get( "/categories?limit=$THREAD_PAGE_SIZE", 'en' );
is( _state(),             'miss', 'an index of 25 is an entry of its own' );
is( _listed_categories(), $THREAD_PAGE_SIZE, 'which lists 25' );
_get( "/categories?limit=$THREAD_PAGE_SIZE", 'en' );
is( _state(), 'hit', 'which the next visitor asking for 25 is served' );
_get( '/categories', 'en' );
is( _listed_categories(), $full_index,
    'while a visitor asking for no limit still gets the full index' );
_get( '/categories?limit=abc', 'en' );
is( _listed_categories(), $full_index, 'as does one whose limit is no number' );

# Every spelling of the full index is the full index's entry. The key named
# the limit as asked, so each one minted an entry of its own.
for my $spelling (qw(abc 100 0100 0)) {
    _get( "/categories?limit=$spelling", 'en' );
    is( _state(), 'hit', "?limit=$spelling is served the full index's entry" );
}
_get( '/categories?limit=200', 'en' );
my $largest = _state();
_get( '/categories?limit=100000', 'en' );
is( _state(), 'hit',  'and a limit past the largest index is the largest' );
is( $largest, 'miss', 'which is an entry of its own' );

$client->get_ok(
    '/categories' => {
        'Accept-Language' => 'en',
        Cookie            => 'gpforum_theme=dark',
    }
);
is( _html('data-theme'), 'dark', 'a dark-theme visitor gets the dark page' );

my ($category) = GPForum::Test::PostgresHarness::connect_schema()
  ->storage->dbh->selectrow_array('SELECT category_id FROM categories LIMIT 1');
_get( "/c/$category?after=anything", 'en' );
_get( "/c/$category?after=anything", 'en' );
isnt( _state() // 'none', 'hit', 'a page past the first is not cached' );

# A miss looks the page up once: the lookup before the page's queries marks
# it, and the render after them stores without asking the cache again.
my $misses = _cache_misses();
_get( "/c/$category", 'en' );
is( _state(), 'miss',             'a category page not cached yet is a miss' );
is( _cache_misses() - $misses, 1, 'which asks the cache once' );

# A hit answers before the page's queries run.
my $app_schema = $client->app->build_controller->gp_schema;
my $storage    = $app_schema->storage;
my $dbh        = $storage->dbh;
my $sent       = 0;
$dbh->{Callbacks} = {
    prepare        => sub { $sent++; return; },
    prepare_cached => sub { $sent++; return; },
};
_get( "/c/$category", 'en' );
delete $dbh->{Callbacks};
is( _state(), 'hit', 'a cached category page is a hit' );
is( $sent,    0,     'and costs no query' );

# The router reads a path with a trailing slash, or with a letter written as
# an escape, as the page's own, and the key named the path as typed: each
# such spelling of a page minted an entry of its own.
my $spelled_entries = _cached_entries();
( my $escaped_category = $category ) =~ s{\A (.)}{sprintf '%%%02X', ord $1}emsx;
for my $spelling (
    "/c/$category/", "/c/$escaped_category",
    '/categories/',  '/%63ategories',
  )
{
    _get( $spelling, 'en' );
    $client->status_is($HTTP_OK);
    is( _state(), 'hit', "$spelling is served the page's own entry" );
}
is( _cached_entries(), $spelled_entries, 'and none of them mints one' );

# A cached page is bytes. It was kept as characters: a title with a
# character past U+00FF (a dash, a curly quote, an emoji) failed the page
# with a 500, and an accented one reached the browser as Latin-1 under a
# UTF-8 header.
my $title = "Identit\N{LATIN SMALL LETTER A WITH GRAVE} \N{EM DASH} prova"
  . " \N{CHECK MARK}";
$dbh->do( 'UPDATE threads SET title = ? WHERE category_id = ?',
    undef, $title, $category );
my $page_cache = $client->app->build_controller->gp_local_cache;
$page_cache->invalidate_tag('forum:public-html');
for my $round (qw(miss hit)) {
    _get( "/c/$category", 'it' );
    $client->status_is( $HTTP_OK, "a title past Latin-1, served on a $round" );
    is( _state(), $round, "($round)" );
    like( $client->tx->res->text,
        qr/\Q$title\E/msx, "and it reads as written on a $round" );
}

# Its id written as PostgreSQL also reads a uuid found the category too, and
# was served under a key of its own.
my $category_entries = _cached_entries();
_get( '/c/' . uc($category) . '?limit=10', 'en' );
$client->status_is( $HTTP_MOVED_PERMANENTLY,
    'a category id in upper case is redirected' );
$client->header_is(
    Location => "/c/$category?limit=10",
    'to the category\'s URL, the query kept'
);
is( _cached_entries(), $category_entries, 'and mints no entry' );

# A thread is one page under /t/ID and /t/ID/SLUG. Any slug used to be
# served, and each minted an entry: a slug that is not the thread's own is
# now sent to its URL, whether the page is cached or not.
my ( $thread, $slug ) =
  $dbh->selectrow_array( q{SELECT t.thread_id, t.slug FROM threads t}
      . q{ JOIN categories c ON c.category_id = t.category_id}
      . q{ JOIN spaces s ON s.space_id = c.space_id}
      . q{ WHERE t.deleted_at IS NULL AND t.visibility = 'public'}
      . q{ AND t.moderation_state = 'visible' AND c.visibility = 'public'}
      . q{ AND s.visibility = 'public' AND c.deleted_at IS NULL LIMIT 1} );
my $canonical = "/t/$thread/$slug";
$page_cache->invalidate_tag("forum:thread:$thread");
_get( "/t/$thread/not-$slug?limit=10", 'en' );
$client->status_is( $HTTP_MOVED_PERMANENTLY,
    'a slug that is not the thread\'s is redirected' );
$client->header_is(
    Location => "$canonical?limit=10",
    'to its own URL, the query kept'
);
_get( $canonical, 'en' );
$client->status_is($HTTP_OK);
is( _state(), 'miss', 'the canonical URL fills the thread\'s entry' );
_get( "/t/$thread", 'en' );
is( _state(), 'hit', 'which the URL without a slug is served' );
_get( "/t/$thread?limit=abc", 'en' );
is( _state(), 'hit', 'as is one whose page size is no number' );
my $entries = _cached_entries();
$sent = 0;
$dbh->{Callbacks} = {
    prepare        => sub { $sent++; return; },
    prepare_cached => sub { $sent++; return; },
};
_get( "/t/$thread/anything-else", 'en' );
delete $dbh->{Callbacks};
$client->status_is( $HTTP_MOVED_PERMANENTLY,
    'a junk slug of a cached thread is redirected' );
$client->header_is( Location => $canonical, 'to the thread\'s URL' );
is( $sent,             0,        'from the cache, with no query' );
is( _cached_entries(), $entries, 'and no entry is minted for it' );

# Its id written as PostgreSQL also reads a uuid found the thread too, and
# was served under a key of its own: every casing of it was another entry.
( my $bare = $thread ) =~ tr/-//d;
for my $spelling ( uc $thread, "{$thread}", $bare ) {
    _get( "/t/$spelling/$slug", 'en' );
    $client->status_is( $HTTP_MOVED_PERMANENTLY,
        "the thread's id spelled $spelling is redirected" );
    $client->header_is( Location => $canonical, 'to the thread\'s URL' );
}
_get( '/t/' . uc $thread, 'en' );
$client->status_is( $HTTP_MOVED_PERMANENTLY, 'as it is without a slug' );
is( _cached_entries(), $entries, 'and none of them mints an entry' );

$storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _get {
    my ( $path, $language ) = @_;

    $client->get_ok( $path => { 'Accept-Language' => $language } );

    return;
}

sub _state {
    return $client->tx->res->headers->header('X-GPForum-Cache');
}

sub _listed_categories {
    return $client->tx->res->dom->find('li.ui-card-list__item')->size;
}

# The entries this process holds: the tiered cache's L1 when GlifiStore is
# configured, the local cache itself otherwise.
sub _cached_entries {
    my $cache = $client->app->build_controller->gp_local_cache;
    my $local = $cache->can('l1') ? $cache->l1 : $cache;

    return scalar keys %{ $local->entries };
}

sub _cache_misses {
    return $client->app->build_controller->gp_local_cache->snapshot->{stats}
      {misses};
}

sub _html {
    my ($attribute) = @_;

    return $client->tx->res->dom->at('html')->attr($attribute);
}

1;
