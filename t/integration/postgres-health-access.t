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
use GPForum::Web::HealthPayload;

our $VERSION = '0.001';

const my $HTTP_OK        => 200;
const my $TOKEN          => 'health-integration-token';
const my $PREVIOUS_TOKEN => 'health-integration-previous';
const my $WRONG_TOKEN    => 'health-integration-tokeX';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the health access test';
}

# /health/ready and /health against the application on PostgreSQL, with the
# metrics token taken from the environment as a deployment sets it: the real
# readiness report (every check, its errors, the runtime) reaches only a
# request carrying the token; anyone else reads the status, under the same
# HTTP code.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;
local $ENV{GPFORUM_METRICS_TOKEN}             = $TOKEN;
local $ENV{GPFORUM_METRICS_TOKENS}            = $PREVIOUS_TOKEN;
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );

my $client = Test::Mojo->new('GPForum');

$client->get_ok( '/health/ready' => { 'X-GPForum-Metrics-Token' => $TOKEN } );
my $report           = $client->tx->res->json;
my $code             = $client->tx->res->code;
my ($database_check) = grep { $_->{name} eq 'database' } @{ $report->{checks} };
is( $database_check->{status}, 'ok', 'the token reads the database check' );
ok( exists $report->{runtime}, 'and the runtime profile' );
is(
    $code,
    GPForum::Web::HealthPayload->ready_status_code( $report->{status} ),
    "the code follows the status ($report->{status})"
);

for my $request (
    [ 'no token',     {} ],
    [ 'wrong token',  { 'X-GPForum-Metrics-Token' => $WRONG_TOKEN } ],
    [ 'wrong Bearer', { Authorization             => "Bearer $WRONG_TOKEN" } ],
  )
{
    my ( $label, $headers ) = @{$request};
    $client->get_ok( '/health/ready' => $headers );
    $client->status_is( $code, "$label: the same code" );
    is_deeply(
        $client->tx->res->json,
        { status => $report->{status}, check => 'ready' },
        "$label: the status alone"
    );
}

$client->get_ok(
    '/health/ready' => { Authorization => "Bearer $PREVIOUS_TOKEN" } );
$client->status_is( $code, 'a previous token: the same code' );
$client->json_has( '/checks', 'and the full report during rotation' );

$client->get_ok('/health')->status_is($HTTP_OK);
is_deeply(
    $client->tx->res->json,
    { status => 'ok' },
    'the summary is the status alone without the token'
);
$client->get_ok( '/health' => { 'X-GPForum-Metrics-Token' => $TOKEN } )
  ->status_is($HTTP_OK)
  ->json_has( '/os', 'and the OS snapshot with it' );

GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

1;
