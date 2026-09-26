# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::DbQueryStats;
use GPForum::Test::DbQueryStatsSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS       => 18;
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

# As DBIx::Class::Storage::DBI calls it: the statement, then each bind value
# already quoted for display. The binds do not change the fingerprint.
$stats->query_start( 'SELECT * FROM posts WHERE thread_id = ?',     q{'41'} );
$stats->query_start( 'SELECT * FROM posts WHERE thread_id = ?',     q{'42'} );
$stats->query_start( 'SELECT * FROM post_bodies WHERE body_id = ?', q{'7'} );
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

# The statistics object counts; it must never write. DBIx::Class's base class
# prints every savepoint to STDERR, and debug(1) is on for the whole process,
# so each nested transaction in production put "SAVEPOINT savepoint_0" and
# "RELEASE SAVEPOINT savepoint_0" in the log.
my $written = q{};
open my $log, '>', \$written or croak 'failed to capture the log';
{
    local *STDERR = $log;
    $stats->debugfh($log);
    $stats->svp_begin('savepoint_0');
    $stats->svp_release('savepoint_0');
    $stats->svp_rollback('savepoint_0');
    $stats->print("anything\n");
}
close $log or croak 'failed to close the log capture';
is( $written, q{}, 'savepoints and prints write nothing to the log' );

1;
