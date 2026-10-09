# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Operations;
use GPForum::Config;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;
use GPForum::Test::BootstrapOperationsSchema;
use Mojolicious;

our $VERSION = '0.001';

# The application cache Bootstrap::Operations hands every request: a
# TieredCache gets the PostgreSQL invalidation bus, on gp_schema and on the
# process's one notification queue, so a write in one Hypnotoad worker drops
# the entry in the others. Nothing else pins that the bus is attached at all.

subtest 'a tiered cache hears the other workers' => sub {
    my $schema      = GPForum::Test::BootstrapOperationsSchema->new;
    my $application = _application( sub { return $schema; } );
    my $controller  = $application->build_controller;
    my $cache       = $controller->gp_local_cache;

    isa_ok( $cache,      'GPForum::Service::Operations::TieredCache' );
    isa_ok( $cache->bus, 'GPForum::Service::Operations::CacheInvalidationBus' );
    is( $cache->bus->schema, $schema, 'the bus writes through gp_schema' );
    is(
        $cache->bus->notifications,
        $controller->gp_pg_notifications,
        'and reads the queue it shares with the realtime listener'
    );
    is( $application->build_controller->gp_local_cache,
        $cache, 'one cache for the application' );
};

subtest 'no schema, no bus' => sub {
    my $absent =
      _application( sub { return undef; } )->build_controller->gp_local_cache;
    isa_ok( $absent, 'GPForum::Service::Operations::TieredCache' );
    is( $absent->bus, undef, 'a gp_schema that answers nothing' );

    my $failing = _application( sub { croak "no database\n"; } )
      ->build_controller->gp_local_cache;
    isa_ok( $failing, 'GPForum::Service::Operations::TieredCache' );
    is( $failing->bus, undef, 'a gp_schema that dies' );
};

subtest 'a process-local cache has no other worker to tell' => sub {
    my $cache = _application(
        sub { return GPForum::Test::BootstrapOperationsSchema->new; },
        glifistore_url => q{}, )->build_controller->gp_local_cache;

    isa_ok( $cache, 'GPForum::Service::Operations::LocalCache' );
    ok( !$cache->can('bus'), 'and nothing to attach a bus to' );
};

done_testing();

# The operations bootstrap alone, its gp_schema replaced by $schema.
sub _application ( $schema, %config ) {
    my $config = GPForum::Config->new(
        environment    => 'testing',
        log_level      => 'fatal',
        glifistore_url => 'tcp://127.0.0.1:7379',
        %config,
    );
    my $runtime     = GPForum::Runtime->new;
    my $application = Mojolicious->new;
    $application->log->level('fatal');
    $application->secrets( ['bootstrap-operations-cache-bus'] );
    GPForum::Bootstrap::Operations->register(
        application    => $application,
        config         => $config,
        runtime        => $runtime,
        runtime_policy => GPForum::OS::RuntimePolicy->new(
            config  => $config,
            runtime => $runtime,
        ),
    );
    $application->helper( gp_schema => $schema );

    return $application;
}

1;
