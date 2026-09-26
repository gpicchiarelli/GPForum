# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::CategoryReader;
use GPForum::Service::Operations::LocalCache;
use GPForum::Service::Operations::SharedCache;
use GPForum::Service::Operations::TieredCache;
use GPForum::Test::ForumReadResultSet;
use GPForum::Test::ForumReadRow;
use GPForum::Test::ForumReadSchema;
use GPForum::Test::OperationsClock;
use GPForum::Test::PublicPageController;
use GPForum::Test::SharedCacheClient;
use GPForum::Web::PublicHttpCache;

our $VERSION = '0.001';

const my $SHORT_TTL_SECONDS   => 5;
const my $AFTER_TTL_EPOCH     => 106;
const my $PRODUCER_CALLS      => 1;
const my $L2_THREAD_ID        => 9;
const my $NEW_THREAD_ID       => 3;
const my $GLIFISTORE_TCP_PORT => 7379;
const my $DEFAULT_TTL_SECONDS => 60;
const my $START_EPOCH         => 100;
const my $FILL_READ_EPOCH     => 104;
const my $FILL_EXPIRY_EPOCH   => 105;
const my $LAST_PAUSED_EPOCH   => 114;
const my $PAUSE_ENDS_EPOCH    => 115;
const my $TAG_PUTS            => 1_000;
const my $CATEGORY_LIMIT      => 10;
const my $HTTP_OK             => 200;
const my $PUBLIC_TAG          => 'forum:public-html';

my $clock  = GPForum::Test::OperationsClock->new;
my $client = GPForum::Test::SharedCacheClient->new;
my $shared = GPForum::Service::Operations::SharedCache->try_connect(
    {
        clock       => $clock,
        connector   => sub { return $client },
        namespace   => 'test-cache',
        ttl_seconds => $SHORT_TTL_SECONDS,
        url         => 'tcp://127.0.0.1:' . $GLIFISTORE_TCP_PORT,
    }
);

ok( $shared, 'shared cache connects through an injected client' );

my $producer_calls = 0;
my $first          = $shared->get_or_set(
    'categories:list:10',
    sub {
        $producer_calls += 1;
        return [ { title => 'General' } ];
    },
    { tags => [ 'categories', 'forum-index' ] },
);

is( $first->[0]{title}, 'General', 'shared cache stores generated value' );
is( $producer_calls,    $PRODUCER_CALLS, 'producer is called on shared miss' );

my $cached_again = $shared->get_or_set(
    'categories:list:10',
    sub {
        $producer_calls += 1;
        return [ { title => 'Unexpected' } ];
    },
);

is( $cached_again->[0]{title},
    'General', 'shared cache returns existing value on hit' );
is( $producer_calls, $PRODUCER_CALLS, 'producer is not called on shared hit' );

$clock->epoch($AFTER_TTL_EPOCH);
is( $shared->get('categories:list:10'),
    undef, 'shared cache expires values by TTL' );

$shared->put( 'thread:1', { id => 1 }, { tags => [ 'thread:1', 'threads' ] } );
$shared->put( 'thread:2', { id => 2 }, { tags => [ 'thread:1', 'threads' ] } );
is( $shared->invalidate_tag('thread:1'),
    1, 'shared tag invalidation erases the tag token' );
is( $shared->get('thread:1'), undef,
    'shared tag invalidation drops first key' );
is( $shared->get('thread:2'),
    undef, 'shared tag invalidation drops second key' );

is(
    GPForum::Service::Operations::SharedCache->try_connect( { url => q{} } ),
    undef, 'empty GlifiStore URL leaves shared cache disabled',
);
throws_ok(
    sub {
        GPForum::Service::Operations::SharedCache->connect_required(
            { url => q{} } );
    },
    qr/\A glifistore_url [ ] is [ ] required/msx,
    'connect_required fails closed without a GlifiStore URL',
);
my $disconnected = GPForum::Service::Operations::SharedCache->connect_required(
    {
        connector => sub { die "unavailable\n" },
        url       => 'tcp://127.0.0.1:' . $GLIFISTORE_TCP_PORT,
    }
);
ok( $disconnected,
    'shared cache stays constructed when the connector cannot connect' );
is( $disconnected->get('thread:hot'),
    undef, 'disconnected shared cache misses instead of skipping L2' );

my $endpoint =
  GPForum::Service::Operations::SharedCache->parse_endpoint(
    'tcp://127.0.0.1:' . $GLIFISTORE_TCP_PORT );
is( $endpoint->{host}, '127.0.0.1',          'TCP endpoint parses host' );
is( $endpoint->{port}, $GLIFISTORE_TCP_PORT, 'TCP endpoint parses port' );

my $unix =
  GPForum::Service::Operations::SharedCache->parse_endpoint(
    'unix:///tmp/glifistore.sock');
is( $unix->{unix_socket_path},
    '/tmp/glifistore.sock', 'UNIX endpoint parses socket path' );

throws_ok(
    sub {
        GPForum::Service::Operations::SharedCache->parse_endpoint(
            'redis://localhost');
    },
    qr/\A glifistore_url [ ] must [ ] be/msx,
    'invalid GlifiStore URL is rejected',
);

my $down_client = GPForum::Test::SharedCacheClient->new( mode => 'down' );
my $down_cache  = GPForum::Service::Operations::SharedCache->new(
    client => $down_client,
    clock  => $clock,
);
is( $down_cache->get('categories:list:10'),
    undef, 'down shared cache misses instead of throwing' );
is( $down_cache->client, undef,
    'an unavailable GlifiStore drops the connection' );
is(
    $down_cache->get_or_set( 'categories:list:10', sub { return ['ok'] } )->[0],
    'ok',
    'down shared cache still produces values from PostgreSQL-backed readers',
);
ok(
    $down_cache->snapshot->{stats}{failures} > 0,
    'down shared cache records transport failures'
);

my $l1 = GPForum::Service::Operations::LocalCache->new(
    clock       => $clock,
    namespace   => 'tiered-l1',
    ttl_seconds => $DEFAULT_TTL_SECONDS,
);
my $l2_client = GPForum::Test::SharedCacheClient->new;
my $l2        = GPForum::Service::Operations::SharedCache->new(
    client      => $l2_client,
    clock       => $clock,
    namespace   => 'tiered-l2',
    ttl_seconds => $DEFAULT_TTL_SECONDS,
);
my $tiered = GPForum::Service::Operations::TieredCache->new(
    l1 => $l1,
    l2 => $l2,
);

$l2->put( 'thread:hot', { id => $L2_THREAD_ID }, { tags => ['threads'] } );
is( $tiered->get('thread:hot')->{id},
    $L2_THREAD_ID, 'tiered cache fills L1 from shared L2' );
is( $l1->get('thread:hot')->{id},
    $L2_THREAD_ID, 'L2 hit is copied into process-local L1' );

$tiered->put( 'thread:new', { id => $NEW_THREAD_ID }, { tags => ['threads'] } );
is( $l2->get('thread:new')->{id},
    $NEW_THREAD_ID, 'tiered writes populate the shared layer' );

$tiered->invalidate_tag('threads');
is( $l1->get('thread:hot'), undef, 'tiered tag invalidation clears L1' );
is( $l2->get('thread:new'), undef, 'tiered tag invalidation clears L2' );

my $down_tiered = GPForum::Service::Operations::TieredCache->new(
    l1 => GPForum::Service::Operations::LocalCache->new( clock => $clock ),
    l2 => $down_cache,
);
is(
    $down_tiered->get_or_set( 'home:latest', sub { return ['live'] } )->[0],
    'live', 'tiered cache keeps serving when GlifiStore is down',
);
is( $down_tiered->get('home:latest')->[0],
    'live', 'process-local L1 remains available after L2 failure' );

ok( $shared->ping, 'shared cache ping succeeds against an injected client' );
ok( !$down_cache->ping,
    'shared cache ping fails closed when GlifiStore is down' );
ok( $tiered->ping, 'tiered cache ping probes the shared layer' );

my $reconnect_attempts = 0;
my $live_client;
my $recovering = GPForum::Service::Operations::SharedCache->connect_required(
    {
        clock     => $clock,
        connector => sub {
            $reconnect_attempts += 1;
            if ( $reconnect_attempts < 2 ) {
                die "unavailable\n";
            }
            $live_client ||= GPForum::Test::SharedCacheClient->new;
            return $live_client;
        },
        url => 'tcp://127.0.0.1:' . $GLIFISTORE_TCP_PORT,
    }
);
is( $recovering->get('home:latest'),
    undef, 'first lookup misses while GlifiStore is down' );
$recovering->put( 'home:latest', ['live'] );
is( $recovering->get('home:latest')->[0],
    'live', 'shared cache retries GlifiStore after a transport failure' );

# The tag used to keep a list of its keys, rewritten by read-modify-write on
# every put: a put that ran inside another lost its key, and a purge left that
# page in L2. Two SharedCache objects over one client stand for two processes
# over one GlifiStore.
my $race_client = GPForum::Test::SharedCacheClient->new;
my $writer      = _shared_over( $race_client, 'race' );
my $sibling     = _shared_over( $race_client, 'race' );
my $raced       = 0;
$race_client->before(
    sub {
        my ( $method, $key ) = @_;

        if ( !$raced && "$method $key" eq "put race:tag:$PUBLIC_TAG" ) {
            $raced = 1;
            $sibling->put( 'page:2', 'two', { tags => [$PUBLIC_TAG] } );
        }
        return;
    }
);
$writer->put( 'page:1', 'one', { tags => [$PUBLIC_TAG] } );
$race_client->before(undef);
ok( $raced, 'a second put ran inside the first' );
$writer->invalidate_tag($PUBLIC_TAG);
is( $writer->get('page:1'),  undef, 'a purge retires the first page' );
is( $sibling->get('page:2'), undef, 'and the page put inside it' );

# However many entries a tag has, its key holds one token.
my $crowd_client = GPForum::Test::SharedCacheClient->new;
my $crowd        = _shared_over( $crowd_client, 'crowd' );
my $tag_key      = "crowd:tag:$PUBLIC_TAG";
$crowd->put( 'page:0', 'zero', { tags => [$PUBLIC_TAG] } );
my $token_length = length $crowd_client->store->{$tag_key};
for my $page ( 1 .. $TAG_PUTS ) {
    $crowd->put( "page:$page", 'page', { tags => [$PUBLIC_TAG] } );
}
is( length $crowd_client->store->{$tag_key},
    $token_length,
    'a thousand pages under one tag leave its key the same size' );
$crowd_client->store->{$tag_key} = 'f' x $token_length;
is( $crowd->get('page:0'),
    undef, 'an entry written under a token since replaced misses' );
$crowd_client->store->{'crowd:entry:legacy'} = $crowd->codec->encode(
    {
        expires_at_epoch => $START_EPOCH + $DEFAULT_TTL_SECONDS,
        tags             => [$PUBLIC_TAG],
        value            => 'old',
    }
);
is( $crowd->get('legacy'),
    undef, 'an entry written before tokens existed misses' );

# GlifiStore rejects the ERASE of an absent key with not_found. Most of the
# tags the outbox invalidates were never cached, and each erase dropped the
# connection and forced a full reconnect.
my $absent_connects = 0;
my $absent_client   = GPForum::Test::SharedCacheClient->new;
my $absent = GPForum::Service::Operations::SharedCache->connect_required(
    {
        clock     => GPForum::Test::OperationsClock->new,
        connector => sub {
            $absent_connects += 1;
            return $absent_client;
        },
        url => 'tcp://127.0.0.1:' . $GLIFISTORE_TCP_PORT,
    }
);
is( $absent->invalidate_tag('forum:thread:42'),
    0, 'a tag nothing was cached under erases nothing' );
is( $absent->invalidate('thread:missing'),
    0, 'nor does a key that is not there' );
is( $absent->get('thread:missing'),       undef, 'which a lookup misses' );
is( $absent->snapshot->{stats}{failures}, 0,     'none of it is a failure' );
is( $absent_connects,                     1,     'and the connection is kept' );

my $overloaded_client =
  GPForum::Test::SharedCacheClient->new( mode => 'overloaded' );
my $overloaded = _shared_over( $overloaded_client, 'overloaded' );
$overloaded->put( 'home:latest', ['live'] );
is( $overloaded->client, $overloaded_client,
    'an overloaded GlifiStore keeps its connection' );
is( $overloaded->retry_after_epoch, $PAUSE_ENDS_EPOCH, 'and pauses L2' );

my $refusing =
  _shared_over(
    GPForum::Test::SharedCacheClient->new( mode => 'invalid_argument' ),
    'refusing' );
$refusing->put( 'home:latest', ['live'] );
ok( $refusing->client, 'a request refused on its merits keeps the connection' );
is( $refusing->retry_after_epoch,           undef, 'and pauses nothing' );
is( $refusing->snapshot->{stats}{failures}, 1,     'but is a failure' );

# While GlifiStore hangs every call costs its timeouts, so after a failure
# nothing reaches it for fifteen seconds: not lookups, not invalidations, not
# the readiness ping.
my $pause_clock    = GPForum::Test::OperationsClock->new;
my $pause_connects = 0;
my $pause_up       = 0;
my $pause_client   = GPForum::Test::SharedCacheClient->new;
my $pausing = GPForum::Service::Operations::SharedCache->connect_required(
    {
        clock     => $pause_clock,
        connector => sub {
            $pause_connects += 1;
            die "unavailable\n" if !$pause_up;
            return $pause_client;
        },
        url => 'tcp://127.0.0.1:' . $GLIFISTORE_TCP_PORT,
    }
);
is( $pausing->retry_after_epoch,
    undef, 'a process that starts before GlifiStore is not paused' );
is( $pausing->get('home:latest'), undef, 'its first lookup misses' );
is( $pausing->snapshot->{retry_after_epoch},
    $PAUSE_ENDS_EPOCH, 'and the failed connect pauses L2 for fifteen seconds' );
for my $epoch ( $START_EPOCH, $LAST_PAUSED_EPOCH ) {
    $pause_clock->epoch($epoch);
    $pausing->get('home:latest');
    $pausing->put( 'home:latest', ['live'], { tags => [$PUBLIC_TAG] } );
    $pausing->invalidate('home:latest');
    $pausing->invalidate_tag($PUBLIC_TAG);
    ok( !$pausing->ping, "ping reports L2 down at $epoch" );
}
is( $pause_connects, 2,
    'nothing reaches GlifiStore while paused, invalidations included' );
is( $pausing->snapshot->{stats}{failures}, 1, 'a skipped call is no failure' );
ok( $pausing->snapshot->{stats}{skipped} > 0, 'it is counted as skipped' );
$pause_up = 1;
$pause_clock->epoch($PAUSE_ENDS_EPOCH);
my $connects_while_paused = $pause_connects;
ok( $pausing->ping, 'when the pause ends the next call connects' );
is( $pause_connects - $connects_while_paused, 1, 'once' );
is( $pausing->retry_after_epoch, undef, 'and a success leaves L2 unpaused' );

# L1 keeps a filled entry no longer than L2 has left for it: the fill used to
# take L1's own default, and an entry with a second left lived another minute.
my $fill_clock = GPForum::Test::OperationsClock->new;
my $fill_l1    = GPForum::Service::Operations::LocalCache->new(
    clock       => $fill_clock,
    ttl_seconds => $DEFAULT_TTL_SECONDS,
);
my $fill_l2 = GPForum::Service::Operations::SharedCache->new(
    client      => GPForum::Test::SharedCacheClient->new,
    clock       => $fill_clock,
    ttl_seconds => $DEFAULT_TTL_SECONDS,
);
my $filling = GPForum::Service::Operations::TieredCache->new(
    l1 => $fill_l1,
    l2 => $fill_l2,
);
$fill_l2->put(
    'thread:ending',
    { id   => $L2_THREAD_ID },
    { tags => ['threads'], ttl_seconds => $SHORT_TTL_SECONDS },
);
$fill_clock->epoch($FILL_READ_EPOCH);
is( $filling->get('thread:ending')->{id},
    $L2_THREAD_ID, 'an entry with a second left in L2 is filled into L1' );
is( $fill_l1->entries->{'thread:ending'}{expires_at_epoch},
    $FILL_EXPIRY_EPOCH, 'for that second only' );
$fill_clock->epoch($FILL_EXPIRY_EPOCH);
is( $filling->get('thread:ending'),
    undef, 'and it is gone from both layers at once' );

my $late_l1 = GPForum::Service::Operations::LocalCache->new(
    clock => GPForum::Test::OperationsClock->new( epoch => $FILL_EXPIRY_EPOCH ),
);
my $early_l2 = _shared_over( GPForum::Test::SharedCacheClient->new, 'early' );
$early_l2->put(
    'thread:ending',
    { id          => $L2_THREAD_ID },
    { ttl_seconds => $SHORT_TTL_SECONDS }
);
is(
    GPForum::Service::Operations::TieredCache->new(
        l1 => $late_l1,
        l2 => $early_l2,
    )->get('thread:ending'),
    undef,
    'an entry with no time left by the L1 clock is a miss'
);
is( $late_l1->get('thread:ending'), undef, 'and is not filled into L1' );

# The anonymous category list is the one entry that spares a query, and it
# held DBIx::Class rows, which do not encode: it never reached L2.
my $category_l2 =
  _shared_over( GPForum::Test::SharedCacheClient->new, 'categories' );
my $category_reader = GPForum::Service::Forum::CategoryReader->new(
    cache => GPForum::Service::Operations::TieredCache->new(
        l1 => GPForum::Service::Operations::LocalCache->new(
            clock => GPForum::Test::OperationsClock->new
        ),
        l2 => $category_l2,
    ),
    schema => GPForum::Test::ForumReadSchema->new(
        resultsets => {
            Category => GPForum::Test::ForumReadResultSet->new(
                rows => [
                    GPForum::Test::ForumReadRow->new(
                        data => {
                            category_id => 'category-1',
                            title       => 'General',
                            visibility  => 'public',
                        }
                    ),
                ],
            ),
        },
    ),
);
my $listed = $category_reader->list_categories( { limit => $CATEGORY_LIMIT } );
is( ref $listed->[0],
    'HASH', 'the anonymous category list is plain column hashes' );
is( $listed->[0]{title}, 'General', 'with each row\'s columns' );
is( $category_l2->snapshot->{stats}{failures},
    0, 'which GlifiStore stores without a failure' );
is(
    $category_l2->get("categories:list:anonymous:$CATEGORY_LIMIT")->[0]{title},
    'General', 'so every process shares it'
);

# A public page looks its key up before the page's queries run. A miss used
# to be looked up again when the page was rendered, one more L2 GET per miss.
my $page_client = GPForum::Test::SharedCacheClient->new;
my $http_cache  = GPForum::Web::PublicHttpCache->new(
    cache => GPForum::Service::Operations::TieredCache->new(
        l1 => GPForum::Service::Operations::LocalCache->new(
            clock => GPForum::Test::OperationsClock->new
        ),
        l2 => _shared_over( $page_client, 'pages' ),
    ),
);
my $page         = GPForum::Test::PublicPageController->new;
my $page_options = {
    key  => 'forum-ssr:categories:en',
    tags => [ $PUBLIC_TAG, 'forum:categories' ],
};
ok(
    !$http_cache->serve_cached( $page, $page_options ),
    'a page not cached yet is not served from the cache'
);
$http_cache->render(
    controller => $page,
    payload    => {},
    status     => $HTTP_OK,
    template   => 'forum/categories',
    %{$page_options},
);
is( $page_client->calls_to( 'get', 'pages:entry:forum-ssr:categories:en' ),
    1, 'a public page miss looks the page up in L2 once' );
is( $page->res->headers->header('X-GPForum-Cache'),
    'miss', 'and renders it as a miss' );
ok( $http_cache->serve_cached( $page, { key => 'forum-ssr:categories:en' } ),
    'the page it stored is served next time' );

done_testing();

sub _shared_over {
    my ( $shared_client, $namespace ) = @_;

    return GPForum::Service::Operations::SharedCache->new(
        client    => $shared_client,
        clock     => GPForum::Test::OperationsClock->new,
        namespace => $namespace,
    );
}

1;
