# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::QueryBudget;
use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

const my $HTTP_OK => 200;
const my $PENDING => 3;
const my $FAILED  => 2;

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run the metrics query budget';
}

# /metrics against PostgreSQL, observed by the request hook like any page.
# It used to count pending and failed outbox messages with two statements
# that differed only in their bind value -- one statement sent twice on
# every scrape -- and it had no budget, so nothing failed on it.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;
local $ENV{GPFORUM_BENCHMARK_QUERY_HEADERS}   = 1;
local $ENV{GPFORUM_METRICS_TOKEN}             = q{};
my $database = GPForum::Test::PgDatabase->fresh;
local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;
my $dbh = $database->dbh;

_outbox_messages( 'pending', $PENDING );
_outbox_messages( 'failed',  $FAILED );
_outbox_messages( 'done',    1 );

my $budget =
  GPForum::Service::Operations::QueryBudget->new->budget_for('metrics');
ok( $budget, 'the catalog has a budget for /metrics' );
is( $budget->{max_duplicate_queries},
    0, 'and it allows no duplicate statement' );

# The first request on a new connection also counts the session settings the
# connection sends (statement_timeout and the rest), whatever the endpoint;
# the second is what every later scrape sends.
my $client = Test::Mojo->new('GPForum');
$client->get_ok('/metrics')->status_is($HTTP_OK);
$client->get_ok('/metrics')->status_is($HTTP_OK);
my $response = $client->tx->res;
is( $response->headers->header('X-GPForum-DB-Budget-Endpoint'),
    'metrics', '/metrics is observed against its own budget' );
is( $response->headers->header('X-GPForum-DB-Duplicate-Queries'),
    0, '/metrics sends no statement twice' );
is( $response->headers->header('X-GPForum-DB-Budget'),
    'ok', 'and stays within its budget' );
cmp_ok(
    $response->headers->header('X-GPForum-DB-Queries'),
    q{<=},
    $budget->{max_queries},
    'its statements fit the budget'
);

# The budget is the measured count, so one more statement -- a duplicate
# put back, or a new read -- fails it, and raising it is a decision.
is(
    $budget->{max_queries},
    $response->headers->header('X-GPForum-DB-Queries'),
    'and the budget is exactly what a scrape sends'
);

my $outbox = $response->json->{outbox};
is( $outbox->{pending}, $PENDING, 'the outbox section counts pending' );
is( $outbox->{failed},  $FAILED,  'and failed, from one statement' );

$dbh->do(q{DELETE FROM outbox_messages WHERE status = 'failed'});
$client->get_ok('/metrics')->status_is($HTTP_OK);
my $after = $client->tx->res->json;
is( $after->{outbox}{failed},
    0, 'a status with no messages counts 0, not undef' );

done_testing();

sub _outbox_messages {
    my ( $status, $count ) = @_;

    for my $number ( 1 .. $count ) {
        $dbh->do(
            q{INSERT INTO outbox_messages (outbox_id, event_id, queue,}
              . q{ job_type, idempotency_key, status, created_at) VALUES}
              . q{ (gen_random_uuid(), gen_random_uuid(), 'events',}
              . q{ 'domain_event.dispatch', ?, ?, now())},
            undef, "metrics-$status-$number", $status
        );
    }

    return;
}

1;
