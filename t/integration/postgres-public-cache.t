# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

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

sub _cache_misses {
    return $client->app->build_controller->gp_local_cache->snapshot->{stats}
      {misses};
}

sub _html {
    my ($attribute) = @_;

    return $client->tx->res->dom->at('html')->attr($attribute);
}

1;
