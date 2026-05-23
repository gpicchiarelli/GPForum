package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;
use Test::Mojo;

use lib 'lib';
use lib 't/lib';

use GPForum::Runtime;
use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Service::Operations::OSPreflight;
use GPForum::Service::Operations::QueryBudget;
use GPForum::Service::Operations::RateLimiter;
use GPForum::Service::Operations::RunbookValidator;
use GPForum::Service::Operations::RuntimeSizing;
use GPForum::Service::Realtime::Hub;
use GPForum::Test::OperationsClock;
use GPForum::Test::ProjectionLagProbe;

our $VERSION = '0.001';

const my $EXPECTED_TESTS            => 48;
const my $HTTP_OK                   => 200;
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
const my $STRICT_WORKER_THRESHOLD   => 99;
const my $STRICT_FD_THRESHOLD       => 1;
const my $THREAD_VIEW_QUERY_BUDGET  => 8;
const my $EXCESSIVE_QUERY_COUNT     => 9;

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
my $metrics = GPForum::Service::Operations::MetricsSnapshot->new(
    clock               => $clock,
    runtime             => $runtime,
    realtime_hub        => $hub,
    rate_limiter        => $limiter,
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
is( $metrics->{realtime}{connections},
    $REALTIME_PROCESSES, 'metrics exposes realtime snapshot' );
is( $metrics->{rate_limits}{buckets},
    $BUCKET_COUNT, 'metrics exposes limiter snapshot' );
is( $metrics->{projections}[0]{projection_name},
    'search_documents', 'metrics exposes projection lag' );
is( $metrics->{query_budgets}{endpoints}{thread_view}{max_queries},
    $THREAD_VIEW_QUERY_BUDGET, 'metrics exposes thread view query budget' );

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
$test->json_is( '/rate_limits/buckets'  => $EXHAUSTED_ALLOWANCE );
$test->json_is( '/realtime/connections' => $EXHAUSTED_ALLOWANCE );

1;
