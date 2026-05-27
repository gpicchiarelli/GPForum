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
    'GPForum::Service::Operations::LocalCache',
    'operations bootstrap registers local cache helper'
);
is_deeply( $application->config('gpforum_runtime_enforcement'),
    $runtime_policy->report,
    'operations bootstrap registers runtime enforcement report' );
ok( $application->config('hypnotoad')->{workers},
    'operations bootstrap registers Hypnotoad runtime config' );

$application->routes->get('/__operations/thread')->to(
    cb => sub {
        my ($controller) = @_;

        return $controller->render( text => 'ok' );
    }
)->name('thread');

my $test = Test::Mojo->new($application);
local $ENV{GPFORUM_BENCHMARK_QUERY_HEADERS} = 1;

$test->get_ok('/__operations/thread')
  ->status_is(200)
  ->header_is( 'X-GPForum-DB-Queries'           => 0 )
  ->header_is( 'X-GPForum-DB-Transactions'      => 0 )
  ->header_is( 'X-GPForum-DB-Duplicate-Queries' => 0 )
  ->header_is( 'X-GPForum-DB-Budget'            => 'ok' )
  ->content_is('ok');

is( $controller->gp_db_query_stats->snapshot->{requests_observed},
    1, 'operations bootstrap observes request query stats' );

done_testing();

1;
