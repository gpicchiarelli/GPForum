# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::OS;
use GPForum::Runtime;
use GPForum::Service::Operations::Readiness;
use GPForum::Service::Operations::SharedCache;
use GPForum::Test::Antivirus;
use GPForum::Test::FailReadinessSchema;
use GPForum::Test::ReadinessRuntime;
use GPForum::Test::ReadinessSchema;
use GPForum::Test::SharedCacheClient;

our $VERSION = '0.001';

const my $EXPECTED_TESTS              => 39;
const my $CHECK_COUNT                 => 13;
const my $ENDPOINT_BUDGET_CHECK_INDEX => 7;
const my $QUERY_BUDGET_DRIFT_INDEX    => 8;
const my $SHARED_CACHE_CHECK_INDEX    => 9;
const my $ANTIVIRUS_CHECK_INDEX       => 10;
const my $PARTITION_CHECK_INDEX       => 11;
const my $PROFILE_CHECK_INDEX         => 12;
const my $SMALL_CACHE                 => 2_048;
const my $SMALL_WEB                   => 4;

plan tests => $EXPECTED_TESTS;

my $ready_schema = GPForum::Test::ReadinessSchema->new;
my $ready        = GPForum::Service::Operations::Readiness->new(
    environment => 'test',
    runtime     => GPForum::Test::ReadinessRuntime->new,
    schema      => $ready_schema,
)->check;

is( $ready->{status},        'ok',   'readiness succeeds when db checks pass' );
is( $ready->{environment},   'test', 'readiness includes environment' );
is( $ready->{runtime}{mode}, 'test', 'readiness includes runtime' );
is( scalar @{ $ready->{checks} },
    $CHECK_COUNT, 'readiness emits individual checks' );
is( $ready->{checks}[0]{name}, 'database', 'readiness checks database first' );
is( $ready->{checks}[1]{name}, 'runtime',  'readiness checks runtime profile' );
is( $ready->{checks}[1]{status}, 'ok',     'runtime readiness check passes' );
is( $ready->{checks}[2]{name}, 'os_preflight', 'readiness checks OS posture' );
is( $ready->{checks}[2]{status},
    'ok', 'readiness accepts complete OS posture' );
is( $ready->{checks}[3]{name},
    'runtime_enforcement', 'readiness checks runtime enforcement posture' );
is( $ready->{checks}[$ENDPOINT_BUDGET_CHECK_INDEX]{name},
    'endpointquerybudget', 'readiness checks query budget resultset' );
is( $ready->{checks}[$QUERY_BUDGET_DRIFT_INDEX]{name},
    'query_budget_drift', 'readiness checks query budget drift' );
is( $ready->{checks}[$QUERY_BUDGET_DRIFT_INDEX]{status},
    'ok', 'readiness accepts synchronized query budgets' );
is( $ready->{checks}[$SHARED_CACHE_CHECK_INDEX]{name},
    'shared_cache', 'readiness checks shared cache posture' );
is( $ready->{checks}[$SHARED_CACHE_CHECK_INDEX]{status},
    'ok', 'shared cache is healthy when disabled' );
is( $ready->{checks}[$SHARED_CACHE_CHECK_INDEX]{mode},
    'disabled', 'shared cache reports disabled when no GlifiStore URL is set' );
is( $ready->{checks}[$ANTIVIRUS_CHECK_INDEX]{name},
    'antivirus', 'readiness checks the upload antivirus' );
is( $ready->{checks}[$ANTIVIRUS_CHECK_INDEX]{status},
    'ok', 'development does not expect an antivirus' );
is( $ready->{checks}[$PARTITION_CHECK_INDEX]{name},
    'partition_horizon', 'readiness checks the partition horizon' );
is( $ready->{checks}[$PARTITION_CHECK_INDEX]{mode},
    'no catalog', 'which a schema without a database handle cannot read' );
is( $ready->{checks}[$PROFILE_CHECK_INDEX]{name},
    'operational_profile', 'readiness checks the operational profile' );
is( $ready->{checks}[$PROFILE_CHECK_INDEX]{status},
    'ok', 'default config meets the development profile' );
is( $ready_schema->search_count,
    3, 'readiness executes bounded resultset probes' );
ok( defined $ready->{latency_ms}, 'readiness reports latency' );

my $failed = GPForum::Service::Operations::Readiness->new(
    environment => 'test',
    runtime     => GPForum::Test::ReadinessRuntime->new,
    schema      => GPForum::Test::FailReadinessSchema->new,
)->check;

is( $failed->{status},            'fail', 'readiness fails when db fails' );
is( $failed->{checks}[0]{status}, 'fail', 'failed check is reported' );

my $degraded = GPForum::Service::Operations::Readiness->new(
    environment => 'test',
    runtime     => GPForum::Runtime->new(
        os_profile => GPForum::OS->from_name('unknown'),
    ),
    schema => GPForum::Test::ReadinessSchema->new,
)->check;

is( $degraded->{status}, 'degraded', 'unknown OS degrades readiness posture' );

my $fallback = GPForum::Service::Operations::Readiness->new(
    environment    => 'test',
    glifistore_url => 'tcp://127.0.0.1:7379',
    runtime        => GPForum::Test::ReadinessRuntime->new,
    schema         => GPForum::Test::ReadinessSchema->new,
)->check;
is( $fallback->{status}, 'degraded',
    'configured but unreachable GlifiStore degrades readiness' );
is( $fallback->{checks}[$SHARED_CACHE_CHECK_INDEX]{mode},
    'local-fallback',
    'unreachable GlifiStore keeps serving from process-local cache' );

my $shared = GPForum::Service::Operations::SharedCache->new(
    client => GPForum::Test::SharedCacheClient->new, );
my $connected = GPForum::Service::Operations::Readiness->new(
    cache          => $shared,
    environment    => 'test',
    glifistore_url => 'tcp://127.0.0.1:7379',
    runtime        => GPForum::Test::ReadinessRuntime->new,
    schema         => GPForum::Test::ReadinessSchema->new,
)->check;
is( $connected->{status}, 'ok',
    'reachable GlifiStore keeps readiness healthy' );
is( $connected->{checks}[$SHARED_CACHE_CHECK_INDEX]{mode},
    'shared', 'reachable GlifiStore reports shared cache mode' );

my $undersized = GPForum::Service::Operations::Readiness->new(
    config => GPForum::Config->new(
        environment             => 'production-medium',
        local_cache_max_entries => $SMALL_CACHE,
        realtime_processes      => 1,
        session_secret          => 'rotated-production-secret',
        web_processes           => $SMALL_WEB,
        worker_processes        => 2,
    ),
    environment => 'production-medium',
    runtime     => GPForum::Test::ReadinessRuntime->new,
    schema      => GPForum::Test::ReadinessSchema->new,
)->check;
is( $undersized->{status}, 'fail',
    'readiness fails below the production-medium floor' );
is( $undersized->{checks}[$PROFILE_CHECK_INDEX]{status},
    'fail', 'operational profile check reports the floor miss' );

my $missing_l2 = GPForum::Service::Operations::Readiness->new(
    config => GPForum::Config->new(
        environment    => 'production-small',
        glifistore_url => q{},
        session_secret => 'rotated-production-secret',
    ),
    environment    => 'production-small',
    glifistore_url => q{},
    runtime        => GPForum::Test::ReadinessRuntime->new,
    schema         => GPForum::Test::ReadinessSchema->new,
)->check;
is( $missing_l2->{status}, 'fail',
    'production fails closed when GlifiStore is missing' );
is( $missing_l2->{checks}[$SHARED_CACHE_CHECK_INDEX]{status},
    'fail', 'shared cache check fails without a GlifiStore URL' );

# ADR 0108. An antivirus that cannot scan degrades readiness and never fails
# it: uploads wait, unserved, and the rest of the forum keeps working.
my $production = GPForum::Config->new(
    environment    => 'production',
    session_secret => 'rotated-production-secret',
);
my $unscanned = _readiness_with( $production, undef );
is( $unscanned->{checks}[$ANTIVIRUS_CHECK_INDEX]{status},
    'degraded', 'production without an antivirus is degraded' );

my $scanning = _readiness_with(
    GPForum::Config->new,
    GPForum::Test::Antivirus->new(
        health_report => {
            mode     => 'clamd',
            status   => 'ok',
            engine   => 'ClamAV 1.4.1',
            database => '27400',
        }
    )
);
is( $scanning->{checks}[$ANTIVIRUS_CHECK_INDEX]{status},
    'ok', 'a healthy clamd keeps readiness ok' );
is( $scanning->{checks}[$ANTIVIRUS_CHECK_INDEX]{engine},
    'ClamAV 1.4.1', 'and readiness reports which engine is scanning' );

my $stalled = _readiness_with(
    GPForum::Config->new,
    GPForum::Test::Antivirus->new(
        health_report => {
            mode   => 'clamd',
            status => 'degraded',
            error  => 'cannot connect',
        }
    )
);
is( $stalled->{status}, 'degraded',
    'an unreachable clamd degrades readiness rather than failing it' );

sub _readiness_with {
    my ( $config, $scanner ) = @_;

    return GPForum::Service::Operations::Readiness->new(
        antivirus   => $scanner,
        config      => $config,
        environment => $config->environment,
        runtime     => GPForum::Test::ReadinessRuntime->new,
        schema      => GPForum::Test::ReadinessSchema->new,
    )->check;
}

1;
