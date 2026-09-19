package main;

use strict;
use warnings;

use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::LocalCache;
use GPForum::Service::Operations::SharedCache;
use GPForum::Service::Operations::TieredCache;
use GPForum::Test::OperationsClock;
use GPForum::Test::SharedCacheClient;

our $VERSION = '0.001';

const my $SHORT_TTL_SECONDS   => 5;
const my $AFTER_TTL_EPOCH     => 106;
const my $PRODUCER_CALLS      => 1;
const my $INVALIDATED_COUNT   => 2;
const my $L2_THREAD_ID        => 9;
const my $NEW_THREAD_ID       => 3;
const my $GLIFISTORE_TCP_PORT => 7379;
const my $DEFAULT_TTL_SECONDS => 60;

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
    $INVALIDATED_COUNT, 'shared tag invalidation removes matching entries' );
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

done_testing();

1;
