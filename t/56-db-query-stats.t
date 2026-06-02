package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::DbQueryStats;
use GPForum::Test::DbQueryStatsSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS       => 17;
const my $HTTP_OK              => 200;
const my $EXPECTED_QUERY_COUNT => 3;

plan tests => $EXPECTED_TESTS;

my $stats  = GPForum::Service::Operations::DbQueryStats->new;
my $schema = GPForum::Test::DbQueryStatsSchema->new;

ok( $stats->attach_to_schema($schema), 'query stats attach to schema storage' );
is( $schema->storage->debugobj,
    $stats, 'query stats install as DBIx::Class debug object' );
is( $schema->storage->debug, 1, 'query stats enable DBIx::Class debug hook' );

my $token = $stats->start_request(
    {
        route          => 'thread',
        endpoint_name  => 'thread_view',
        correlation_id => 'request-test-1',
    }
);

$stats->query_start('SELECT * FROM posts WHERE thread_id = ?');
$stats->query_start('SELECT * FROM posts WHERE thread_id = ?');
$stats->query_start('SELECT * FROM post_bodies WHERE body_id = ?');
$stats->txn_begin;
$stats->txn_commit;

my $request_stats = $stats->finish_request(
    $token,
    {
        route         => 'thread',
        endpoint_name => 'thread_view',
        status        => $HTTP_OK,
    }
);

is( $request_stats->{queries},
    $EXPECTED_QUERY_COUNT, 'request records observed query count' );
is( $request_stats->{transactions},
    1, 'request records observed transaction count' );
is( $request_stats->{duplicate_queries},
    1, 'request records duplicate query count' );
is( scalar @{ $request_stats->{duplicate_fingerprints} },
    1, 'request records duplicate query fingerprint' );
is( $request_stats->{attached},
    1, 'request records attached DB observer state' );
is( $request_stats->{correlation_id},
    'request-test-1', 'request records correlation id' );
ok(
    defined $request_stats->{duration_ms} && $request_stats->{duration_ms} >= 0,
    'request records duration in milliseconds'
);

$stats->record_budget_observation(
    $request_stats->{request_id},
    {
        status     => 'fail',
        budget     => { max_queries => 2, max_transactions => 1 },
        observed   => { queries     => 3, transactions     => 1 },
        violations => ['queries'],
    }
);

my $snapshot = $stats->snapshot;

is( $snapshot->{attached},          1, 'snapshot reports attached state' );
is( $snapshot->{requests_observed}, 1, 'snapshot counts observed requests' );
is( $snapshot->{total_queries},
    $EXPECTED_QUERY_COUNT, 'snapshot counts total queries' );
is( $snapshot->{total_transactions}, 1, 'snapshot counts total transactions' );
is( $snapshot->{duplicate_query_warnings},
    1, 'snapshot counts duplicate query warnings' );
is( $snapshot->{query_budget_mismatches},
    1, 'snapshot counts query budget mismatches' );
is( $snapshot->{last_request}{query_budget_status},
    'fail', 'snapshot exposes last request budget status' );

1;
