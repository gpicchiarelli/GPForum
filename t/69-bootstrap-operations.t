# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Test::Mojo;
use Test::More;

use lib 'lib';

use GPForum::Bootstrap::Operations;
use GPForum::Config;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;
use GPForum::Service::Operations::DbQueryStats;
use GPForum::Service::Operations::LocalCache;
use GPForum::Service::Operations::TieredCache;
use Mojolicious;

our $VERSION = '0.001';

can_ok( 'GPForum::Bootstrap::Operations', 'register' );

my $config = GPForum::Config->new(
    environment => 'testing',
    log_level   => 'fatal',
);
my $runtime        = GPForum::Runtime->new;
my $runtime_policy = GPForum::OS::RuntimePolicy->new(
    config  => $config,
    runtime => $runtime,
);
my $application = Mojolicious->new;
$application->secrets( ['bootstrap-operations-test'] );

GPForum::Bootstrap::Operations->register(
    application    => $application,
    config         => $config,
    runtime        => $runtime,
    runtime_policy => $runtime_policy,
);

my $controller = $application->build_controller;

is( $controller->gp_config,
    $config, 'operations bootstrap registers config helper' );
is( $controller->gp_runtime,
    $runtime, 'operations bootstrap registers runtime helper' );
is( $controller->gp_runtime_policy,
    $runtime_policy, 'operations bootstrap registers runtime policy helper' );
isa_ok(
    $controller->gp_db_query_stats,
    'GPForum::Service::Operations::DbQueryStats',
    'operations bootstrap registers DB query stats helper'
);
isa_ok(
    $controller->gp_local_cache,
    'GPForum::Service::Operations::TieredCache',
    'operations bootstrap wires GlifiStore as shared L2'
);

my $degraded_application = Mojolicious->new;
$degraded_application->secrets( ['bootstrap-operations-degraded'] );
GPForum::Bootstrap::Operations->register(
    application => $degraded_application,
    config      => GPForum::Config->new(
        environment    => 'testing',
        glifistore_url => 'tcp://127.0.0.1:1',
        log_level      => 'fatal',
    ),
    runtime        => $runtime,
    runtime_policy => $runtime_policy,
);
isa_ok(
    $degraded_application->build_controller->gp_local_cache,
    'GPForum::Service::Operations::TieredCache',
    'unreachable GlifiStore still wires shared L2',
);

my $local_only = Mojolicious->new;
$local_only->secrets( ['bootstrap-operations-local'] );
GPForum::Bootstrap::Operations->register(
    application => $local_only,
    config      => GPForum::Config->new(
        environment    => 'testing',
        glifistore_url => q{},
        log_level      => 'fatal',
    ),
    runtime        => $runtime,
    runtime_policy => $runtime_policy,
);
isa_ok(
    $local_only->build_controller->gp_local_cache,
    'GPForum::Service::Operations::LocalCache',
    'development-style empty GlifiStore URL keeps process-local L1',
);
is_deeply( $application->config('gpforum_runtime_enforcement'),
    $runtime_policy->report,
    'operations bootstrap registers runtime enforcement report' );
ok( $application->config('hypnotoad')->{workers},
    'operations bootstrap registers Hypnotoad runtime config' );

$application->helper(
    gp_schema => sub {
        return GPForum::Test::BootstrapOperationsSchema->new;
    }
);
$application->helper(
    gp_realtime_hub => sub {
        return GPForum::Test::BootstrapOperationsRealtimeHub->new;
    }
);

isa_ok(
    $controller->gp_metrics_snapshot,
    'GPForum::Service::Operations::MetricsSnapshot',
    'operations bootstrap constructs metrics snapshot helper'
);
isa_ok(
    $controller->gp_readiness,
    'GPForum::Service::Operations::Readiness',
    'operations bootstrap constructs readiness helper'
);

# With scanning off there is no antivirus -- and its absence must not shift the
# readiness helper's other dependencies out of place.
my $readiness = $controller->gp_readiness;
is( $readiness->antivirus, undef,
    'readiness has no antivirus when scanning is off' );
is( $readiness->config,      $config,   'readiness keeps its config' );
is( $readiness->environment, 'testing', 'readiness keeps its environment' );

my $thread_route = $application->routes->get('/__operations/thread');
$thread_route->to(
    cb => sub {
        my ($handler) = @_;

        return $handler->render( text => 'ok' );
    }
);
$thread_route->name('thread');

my $test = Test::Mojo->new($application);
local $ENV{GPFORUM_BENCHMARK_QUERY_HEADERS} = 1;

$test->get_ok('/__operations/thread');
$test->status_is(200);
$test->header_is( 'X-GPForum-DB-Queries'           => 0 );
$test->header_is( 'X-GPForum-DB-Transactions'      => 0 );
$test->header_is( 'X-GPForum-DB-Duplicate-Queries' => 0 );
$test->header_is( 'X-GPForum-DB-Budget'            => 'ok' );
$test->content_is('ok');

is( $controller->gp_db_query_stats->snapshot->{requests_observed},
    1, 'operations bootstrap observes request query stats' );

done_testing();

package GPForum::Test::BootstrapOperationsSchema;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

package GPForum::Test::BootstrapOperationsRealtimeHub;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

1;
