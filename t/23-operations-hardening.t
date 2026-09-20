package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;
use Test::Mojo;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Runtime;
use GPForum::Service::Operations::LocalCache;
use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Service::Operations::DbQueryStats;
use GPForum::Service::Operations::OSPreflight;
use GPForum::Service::Operations::QueryBudget;
use GPForum::Service::Operations::RateLimiter;
use GPForum::Service::Operations::SecurityTelemetry;
use GPForum::Service::Operations::RunbookValidator;
use GPForum::Service::Operations::RuntimeSizing;
use GPForum::Service::Realtime::Hub;
use GPForum::Test::MetricsSnapshot;
use GPForum::Test::OperationsClock;
use GPForum::Test::ProjectionLagProbe;
use GPForum::Test::QueryBudgetResultSet;
use GPForum::Test::QueryBudgetSchema;

our $VERSION = '0.001';

{

    package GPForum::Test::RealtimeSupervisor;

    sub new {
        my ( $class, %input ) = @_;

        return bless { enabled => $input{enabled} ? 1 : 0 }, $class;
    }

    sub snapshot {
        my ($self) = @_;

        return {
            enabled  => $self->{enabled} ? 1 : 0,
            running  => 0,
            stats    => {},
            listener => {
                listen_notify_received => 0,
            },
        };
    }
}

const my $EXPECTED_TESTS            => 106;
const my $HTTP_OK                   => 200;
const my $HTTP_UNAUTHORIZED         => 401;
const my $RATE_LIMIT                => 2;
const my $WINDOW_SECONDS            => 60;
const my $RESET_EPOCH               => 160;
const my $RESET_CLOCK_EPOCH         => 200;
const my $RETENTION_DAYS            => 30;
const my $WEB_PROCESSES             => 2;
const my $WORKER_PROCESSES          => 4;
const my $REALTIME_PROCESSES        => 1;
const my $BAD_WEB_PROCESSES         => 1;
const my $BAD_WORKER_PROCESSES      => 99;
const my $BAD_REALTIME_PROCESSES    => 0;
const my $FIRST_REMAINING_ALLOWANCE => 1;
const my $EXHAUSTED_ALLOWANCE       => 0;
const my $BUCKET_COUNT              => 1;
const my $METRICS_ROTATION_HITS     => 3;
const my $STRICT_WORKER_THRESHOLD   => 99;
const my $STRICT_FD_THRESHOLD       => 1;
const my $THREAD_VIEW_QUERY_BUDGET  => 8;
const my $EXCESSIVE_QUERY_COUNT     => 9;
const my $CACHE_ENTRIES             => 1;

plan tests => $EXPECTED_TESTS;

my $clock   = GPForum::Test::OperationsClock->new;
my $limiter = GPForum::Service::Operations::RateLimiter->new( clock => $clock );

my $first = $limiter->check(
    {
        scope          => 'ip',
        actor_id       => '127.0.0.1',
        action         => 'post.create',
        limit          => $RATE_LIMIT,
        window_seconds => $WINDOW_SECONDS,
    }
);
ok( $first->{ok}, 'first rate limited action is allowed' );
is( $first->{remaining}, $FIRST_REMAINING_ALLOWANCE,
    'first action decrements remaining count' );
is( $first->{reset_at_epoch}, $RESET_EPOCH,
    'rate limiter exposes reset epoch' );

my $allowed_again = $limiter->check(
    {
        scope          => 'ip',
        actor_id       => '127.0.0.1',
        action         => 'post.create',
        limit          => $RATE_LIMIT,
        window_seconds => $WINDOW_SECONDS,
    }
);
ok( $allowed_again->{ok}, 'second rate limited action is allowed' );
is( $allowed_again->{remaining},
    $EXHAUSTED_ALLOWANCE, 'second action exhausts remaining count' );

my $third = $limiter->check(
    {
        scope          => 'ip',
        actor_id       => '127.0.0.1',
        action         => 'post.create',
        limit          => $RATE_LIMIT,
        window_seconds => $WINDOW_SECONDS,
    }
);
ok( !$third->{ok}, 'third rate limited action is denied' );
is( $third->{mitigation_hint}, 'slow_down',
    'rate limit gives mitigation hint' );
is( $limiter->snapshot->{buckets},
    $BUCKET_COUNT, 'rate limiter snapshot counts buckets' );

$clock->epoch($RESET_CLOCK_EPOCH);
my $reset = $limiter->check(
    {
        scope          => 'ip',
        actor_id       => '127.0.0.1',
        action         => 'post.create',
        limit          => $RATE_LIMIT,
        window_seconds => $WINDOW_SECONDS,
    }
);
ok( $reset->{ok}, 'rate limit resets after window' );
is( $reset->{observed_count}, $BUCKET_COUNT,
    'reset window starts fresh count' );

my $runtime = GPForum::Runtime->new(
    web_processes      => $WEB_PROCESSES,
    worker_processes   => $WORKER_PROCESSES,
    realtime_processes => $REALTIME_PROCESSES,
);
my $hub = GPForum::Service::Realtime::Hub->new;
$hub->register_connection( 'connection-1', { user_id => 'user-1' }, undef );
my $local_cache = GPForum::Service::Operations::LocalCache->new(
    clock     => $clock,
    namespace => 'metrics-cache',
);
$local_cache->put( 'categories:list', [] );
my $security_telemetry =
  GPForum::Service::Operations::SecurityTelemetry->new( clock => $clock );
$security_telemetry->record( 'csrf_failure', { status => 403 } );
my $query_stats = GPForum::Service::Operations::DbQueryStats->new;
my $query_token =
  $query_stats->start_request(
    { route => 'thread', endpoint_name => 'thread_view' } );
$query_stats->query_start('SELECT * FROM posts WHERE thread_id = ?');
$query_stats->query_start('SELECT * FROM posts WHERE thread_id = ?');
$query_stats->txn_begin;
$query_stats->finish_request(
    $query_token,
    {
        route         => 'thread',
        endpoint_name => 'thread_view',
        status        => $HTTP_OK,
    }
);
my $metrics = GPForum::Service::Operations::MetricsSnapshot->new(
    clock               => $clock,
    db_query_stats      => $query_stats,
    local_caches        => [$local_cache],
    runtime             => $runtime,
    realtime_hub        => $hub,
    realtime_supervisor =>
      GPForum::Test::RealtimeSupervisor->new( enabled => 1 ),
    rate_limiter        => $limiter,
    security_telemetry  => $security_telemetry,
    projection_trackers => [ GPForum::Test::ProjectionLagProbe->new ],
)->collect;

is( $metrics->{generated_at},
    '2026-05-23T12:00:00Z', 'metrics snapshot has timestamp' );
is( $metrics->{runtime}{web_processes},
    $WEB_PROCESSES, 'metrics exposes runtime profile' );
ok( $metrics->{runtime}{os}{name},  'runtime profile exposes OS name' );
ok( $metrics->{os}{cpu_count} >= 1, 'metrics exposes OS CPU count' );
ok(
    exists $metrics->{os}{supports_reuseport},
    'metrics exposes OS socket capability'
);
ok(
    exists $metrics->{os}{resources}{open_file_descriptors},
    'metrics exposes file descriptor resource posture'
);
ok(
    exists $metrics->{os_features}{reuseport}{enabled},
    'metrics exposes effective OS feature flags'
);
ok( exists $metrics->{os_sockets}{reuseaddr}{enabled},
    'metrics exposes OS socket policy' );
ok(
    exists $metrics->{os_processes}{classes}{web_worker},
    'metrics exposes OS process class policy'
);
ok(
    exists $metrics->{os_preflight}{status},
    'metrics exposes OS preflight status'
);
ok(
    exists $metrics->{os_preflight}{checks},
    'metrics exposes OS preflight checks'
);
is( $metrics->{local_caches}[0]{namespace},
    'metrics-cache', 'metrics exposes local cache namespace' );
is( $metrics->{local_caches}[0]{entries},
    $CACHE_ENTRIES, 'metrics exposes local cache entry count' );
is( $metrics->{local_caches}[0]{stats}{writes},
    $CACHE_ENTRIES, 'metrics exposes local cache writes' );
is( $metrics->{realtime}{connections},
    $REALTIME_PROCESSES, 'metrics exposes realtime snapshot' );
ok(
    exists $metrics->{realtime}{broadcast},
    'metrics exposes realtime broadcast counter'
);
ok(
    exists $metrics->{realtime}{delivered},
    'metrics exposes realtime delivered counter'
);
ok(
    exists $metrics->{realtime}{failed},
    'metrics exposes realtime failed counter'
);
ok(
    exists $metrics->{realtime}{malformed},
    'metrics exposes realtime malformed counter'
);
is( $metrics->{realtime_listener}{enabled},
    1, 'metrics exposes realtime listener supervisor snapshot' );
ok( exists $metrics->{realtime_listener}{listener}{listen_notify_received},
    'metrics exposes listener LISTEN/NOTIFY counter' );
is( $metrics->{rate_limits}{buckets},
    $BUCKET_COUNT, 'metrics exposes limiter snapshot' );
is( $metrics->{rate_limits}{rate_limit_allowed},
    3, 'metrics exposes allowed rate-limit counter' );
is( $metrics->{rate_limits}{rate_limit_blocked},
    1, 'metrics exposes blocked rate-limit counter' );
is( $metrics->{rate_limits}{degraded_rate_limiter_active},
    0, 'metrics exposes degraded rate-limiter state' );
is( $metrics->{security}{total}, 1, 'metrics exposes security event total' );
is( $metrics->{security}{events}{csrf_failure}{count},
    1, 'metrics exposes csrf failure count' );
is( $metrics->{security}{events}{csrf_failure}{last_metadata}{status},
    403, 'metrics exposes safe security metadata' );
is( $metrics->{projections}[0]{projection_name},
    'search_documents', 'metrics exposes projection lag' );
is( $metrics->{db_query_stats}{requests_observed},
    1, 'metrics exposes observed DB request count' );
is( $metrics->{db_query_stats}{last_request}{queries},
    2, 'metrics exposes observed DB query count' );
is( $metrics->{db_query_stats}{last_request}{transactions},
    1, 'metrics exposes observed DB transaction count' );
is( $metrics->{db_query_stats}{duplicate_query_warnings},
    1, 'metrics exposes duplicate DB query warnings' );
is( $metrics->{query_budgets}{endpoints}{thread_view}{max_queries},
    $THREAD_VIEW_QUERY_BUDGET, 'metrics exposes thread view query budget' );
is_deeply( $metrics->{query_budget_drift},
    {}, 'metrics omit query budget drift without schema' );

my $runbook_validator = GPForum::Service::Operations::RunbookValidator->new;
my $bad_backup        = $runbook_validator->validate_backup(
    {
        postgres_method => 'pg_basebackup',
    }
);
ok( !$bad_backup->{ok}, 'incomplete backup runbook is rejected' );
ok(
    $bad_backup->{missing}{retention_days},
    'backup runbook requires retention'
);

my $good_backup = $runbook_validator->validate_backup(
    {
        postgres_method       => 'pg_basebackup',
        object_storage_policy => 'versioned bucket backup',
        configuration_policy  => 'encrypted repository snapshot',
        retention_days        => $RETENTION_DAYS,
        restore_test_cadence  => 'monthly',
    }
);
ok( $good_backup->{ok}, 'complete backup runbook is accepted' );

my $bad_rollback = $runbook_validator->validate_rollback(
    {
        trigger => 'failed health checks',
    }
);
ok( !$bad_rollback->{ok}, 'incomplete rollback runbook is rejected' );
ok(
    $bad_rollback->{missing}{health_check},
    'rollback runbook requires health check'
);

my $good_rollback = $runbook_validator->validate_rollback(
    {
        trigger      => 'failed health checks',
        owner        => 'operator',
        health_check => '/health/ready',
        forward_fix  => 'documented',
    }
);
ok( $good_rollback->{ok}, 'complete rollback runbook is accepted' );

my $sizing = GPForum::Service::Operations::RuntimeSizing->new;
ok( $sizing->validate($runtime)->{ok}, 'balanced runtime sizing is accepted' );
ok(
    GPForum::Service::Operations::OSPreflight->new( runtime => $runtime )
      ->check->{status},
    'OS preflight returns a status for balanced runtime'
);
is(
    GPForum::Service::Operations::OSPreflight->new(
        runtime                 => $runtime,
        min_recommended_workers => $STRICT_WORKER_THRESHOLD,
    )->check->{status},
    'degraded',
    'OS preflight degrades below configured worker threshold'
);
is(
    GPForum::Service::Operations::OSPreflight->new(
        runtime                   => $runtime,
        max_open_file_descriptors => $STRICT_FD_THRESHOLD,
    )->check->{status},
    'degraded',
    'OS preflight degrades above configured file descriptor threshold'
);

my $query_budget = GPForum::Service::Operations::QueryBudget->new;
is( $query_budget->budget_for('thread_view')->{max_queries},
    $THREAD_VIEW_QUERY_BUDGET,
    'query budget catalog exposes thread view budget' );
is(
    $query_budget->observe( 'thread_view',
        { queries => $THREAD_VIEW_QUERY_BUDGET, transactions => 1 } )->{status},
    'ok',
    'query budget accepts observations within budget'
);
is(
    $query_budget->observe( 'thread_view',
        { queries => $EXCESSIVE_QUERY_COUNT, transactions => 1 } )->{status},
    'fail',
    'query budget rejects observations over budget'
);
is( $query_budget->observe( 'unknown_endpoint', { queries => 1 } )->{status},
    'unknown', 'query budget reports unknown endpoints explicitly' );
ok(
    exists $query_budget->snapshot->{endpoints}{search},
    'query budget snapshot includes search endpoint'
);
is( $query_budget->budget_for('notifications')->{max_queries},
    4, 'query budget catalog includes notifications endpoint' );
is_deeply(
    $query_budget->observe(
        'thread_view',
        {
            duplicate_queries => 1,
            queries           => 1,
            transactions      => 1,
        }
    )->{violations},
    ['duplicate_queries'],
    'query budget observes duplicate query violations'
);
ok(
    !eval {
        $query_budget->enforce( 'thread_view',
            { queries => $EXCESSIVE_QUERY_COUNT, transactions => 1 } );
        1;
    },
    'query budget hard-fail mode can throw on violations'
);
my $query_budget_resultset = GPForum::Test::QueryBudgetResultSet->new;
my $query_budget_schema    = GPForum::Test::QueryBudgetSchema->new(
    budget_resultset => $query_budget_resultset, );
my $sync = $query_budget->sync_schema($query_budget_schema);
is(
    $sync->{synced},
    scalar keys %{ $query_budget->catalog },
    'query budget sync writes every catalog endpoint'
);
is(
    $sync->{written},
    scalar keys %{ $query_budget->catalog },
    'first query budget sync inserts every catalog row'
);
my $updated_count = scalar @{ $query_budget_resultset->updated };
my $same_sync     = $query_budget->sync_schema($query_budget_schema);
is( $same_sync->{written}, 0,
    'unchanged query budget sync does not rewrite rows' );
is(
    $same_sync->{skipped},
    scalar keys %{ $query_budget->catalog },
    'unchanged query budget sync skips every catalog endpoint'
);
is( scalar @{ $query_budget_resultset->updated },
    $updated_count, 'unchanged query budget sync keeps the stored rows' );
$query_budget_resultset->skip_search_count(1);
my $raced_sync = $query_budget->sync_schema($query_budget_schema);
is( $raced_sync->{written},
    0, 'unique query budget race does not rewrite rows' );
is(
    $raced_sync->{skipped},
    scalar keys %{ $query_budget->catalog },
    'unique query budget race skips every catalog endpoint'
);
is( scalar @{ $query_budget_resultset->updated },
    $updated_count,
    'unique query budget race does not insert a second catalog' );
is(
    $raced_sync->{synced},
    scalar keys %{ $query_budget->catalog },
    'unique query budget race still reports the catalog'
);
is(
    $query_budget_resultset->rows->{thread_view}->get_column('max_queries'),
    $THREAD_VIEW_QUERY_BUDGET,
    'query budget sync persists thread view budget'
);
is( $query_budget->drift_report($query_budget_schema)->{status},
    'ok', 'query budget drift report accepts synchronized catalog' );
$query_budget_resultset->rows->{thread_view}->update( { max_queries => 1 } );
is( $query_budget->drift_report($query_budget_schema)->{status},
    'fail', 'query budget drift report rejects mismatched stored budget' );
is( $query_budget->drift_report($query_budget_schema)->{mismatched}[0],
    'thread_view', 'query budget drift report names mismatched endpoint' );

my $drift_metrics = GPForum::Service::Operations::MetricsSnapshot->new(
    clock        => $clock,
    runtime      => $runtime,
    schema       => $query_budget_schema,
    query_budget => $query_budget,
)->collect;
is( $drift_metrics->{query_budget_drift}{status},
    'fail', 'metrics expose query budget drift when schema is available' );
my $bad_runtime = GPForum::Runtime->new(
    web_processes      => $BAD_WEB_PROCESSES,
    worker_processes   => $BAD_WORKER_PROCESSES,
    realtime_processes => $BAD_REALTIME_PROCESSES,
);
my $bad_sizing = $sizing->validate($bad_runtime);
ok( !$bad_sizing->{ok}, 'bad runtime sizing is rejected' );
is(
    $bad_sizing->{errors}{realtime_processes},
    'realtime_processes must be positive',
    'runtime sizing requires realtime process count'
);
is(
    $bad_sizing->{errors}{worker_processes},
    'worker process count exceeds web ratio',
    'runtime sizing limits worker ratio'
);

my $test = Test::Mojo->new('GPForum');
$test->get_ok('/metrics');
$test->status_is($HTTP_OK);
$test->json_has('/runtime/web_processes');
$test->json_has('/local_caches/0/namespace');
$test->json_has('/rate_limits/buckets');
my $metrics_json = $test->tx->res->json;
cmp_ok( $metrics_json->{rate_limits}{buckets},
    '>=', $EXHAUSTED_ALLOWANCE, 'rate limit bucket metric is non-negative' );
$test->json_is( '/realtime/connections' => $EXHAUSTED_ALLOWANCE );
$test->json_has('/realtime/broadcast');
$test->json_has('/realtime/delivered');
$test->json_has('/realtime/failed');
$test->json_has('/realtime/malformed');
$test->json_has('/realtime_listener/listener/listen_notify_received');

my $protected_metrics = GPForum::Test::MetricsSnapshot->new;
my $protected_test    = Test::Mojo->new('GPForum');
$protected_test->app->helper(
    gp_config => sub {
        return GPForum::Config->new(
            metrics_token           => 'metrics-secret',
            previous_metrics_tokens => ['previous-metrics'],
        );
    }
);
$protected_test->app->helper(
    gp_metrics_snapshot => sub {
        return $protected_metrics;
    }
);

$protected_test->get_ok('/metrics');
$protected_test->status_is($HTTP_UNAUTHORIZED);
$protected_test->json_is( '/status' => 'unauthorized' );
is( $protected_metrics->collected,
    0, 'unauthorized metrics request does not collect snapshot' );

$protected_test->get_ok(
    '/metrics' => { Authorization => 'Bearer metrics-secret' } );
$protected_test->status_is($HTTP_OK);
$protected_test->json_is( '/status' => 'ok' );
is( $protected_metrics->collected,
    1, 'bearer token authorizes metrics snapshot' );

$protected_test->get_ok(
    '/metrics' => { 'X-GPForum-Metrics-Token' => 'metrics-secret' } );
$protected_test->status_is($HTTP_OK);
is( $protected_metrics->collected,
    2, 'metrics token header authorizes metrics snapshot' );

$protected_test->get_ok(
    '/metrics' => { 'X-GPForum-Metrics-Token' => 'previous-metrics' } );
$protected_test->status_is($HTTP_OK);
is( $protected_metrics->collected,
    $METRICS_ROTATION_HITS,
    'a previous metrics token still authorizes during rotation' );

1;
