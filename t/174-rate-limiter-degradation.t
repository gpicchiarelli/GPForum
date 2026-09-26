# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Service::Operations::RateLimiter;
use GPForum::Service::Operations::RateLimiter::DegradationPolicy;
use GPForum::Service::Operations::RateLimiter::PostgreSQLStore;
use GPForum::Service::Operations::SecurityTelemetry;
use GPForum::Test::FailingRateLimitStore;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::RateLimitDegradationConfig;
use GPForum::Test::RateLimitSchema;
use GPForum::Test::Schema;

our $VERSION = '0.001';

const my $ACTION_LIMIT      => 1;
const my $WINDOW_SECONDS    => 60;
const my $FIXED_EPOCH       => 1_716_464_000;
const my $FAIL_CLOSED_RESET => $FIXED_EPOCH + $WINDOW_SECONDS;
const my $HTTP_TOO_MANY     => 429;
const my $TWO_CHECKS        => 2;

subtest 'healthy primary store stays authoritative' => sub {
    my $telemetry = _telemetry();
    my $audit     = GPForum::Test::Schema->new;
    my $limiter   = _limiter(
        {
            audit     => $audit,
            primary   => _postgresql_store(),
            telemetry => $telemetry,
        }
    );

    my $first = $limiter->check( _limit_input() );
    ok( $first->{ok}, 'first authoritative check is allowed' );
    is( $first->{store}, 'postgresql', 'decision comes from the shared store' );
    ok( !$first->{degraded}, 'healthy decision is not degraded' );
    ok( !defined $first->{denied_reason},
        'allowed decision carries no denial reason' );

    my $retry = $limiter->check( _limit_input() );
    ok( !$retry->{ok}, 'second authoritative check is denied' );
    is( $retry->{denied_reason},
        'over_limit', 'authoritative denial names the limit' );
    ok( !$retry->{degraded}, 'authoritative denial is not degraded' );

    my $stats = $limiter->snapshot->{stats};
    is( $stats->{primary_failures}, 0, 'healthy store records no failures' );
    is( $stats->{fallback_used}, 0, 'healthy store never uses the fallback' );
    is( $stats->{blocked_over_limit},
        1, 'over-limit denial increments the over-limit counter' );
    is( $stats->{blocked_degraded},
        0, 'over-limit denial does not increment the degraded counter' );
    is( $audit->created_for('AuditLog')->[0]{action},
        'rate_limit.blocked', 'over-limit denial writes an audit record' );
    ok( !exists $telemetry->snapshot->{events}{rate_limit_fail_closed},
        'healthy store emits no fail-closed telemetry' );
};

subtest 'permissive mode degrades to the local memory store' => sub {
    my $telemetry = _telemetry();
    my $audit     = GPForum::Test::Schema->new;
    my $limiter   = _limiter(
        {
            audit     => $audit,
            policy    => _policy('permissive'),
            primary   => GPForum::Test::FailingRateLimitStore->new,
            telemetry => $telemetry,
        }
    );

    my $first = $limiter->check( _limit_input() );
    ok( $first->{ok}, 'permissive mode keeps serving when the store throws' );
    is( $first->{store},    'local_memory', 'permissive decision is local' );
    is( $first->{degraded}, 1, 'permissive decision is flagged degraded' );

    my $retry = $limiter->check( _limit_input() );
    ok( !$retry->{ok}, 'permissive mode still enforces the local allowance' );
    is( $retry->{denied_reason},
        'over_limit', 'permissive denial is an over-limit denial' );
    is( $retry->{degraded}, 1, 'permissive denial stays flagged degraded' );

    my $stats = $limiter->snapshot->{stats};
    is( $stats->{primary_failures},
        $TWO_CHECKS, 'permissive mode counts every primary failure' );
    is( $stats->{fallback_used},
        $TWO_CHECKS, 'permissive mode counts every fallback decision' );
    is( $stats->{blocked_over_limit},
        1, 'permissive denial counts as an over-limit block' );
    is( $stats->{blocked_degraded},
        0, 'permissive denial is not a degraded block' );
    is( $audit->created_for('AuditLog')->[0]{action},
        'rate_limit.blocked',
        'permissive denial still writes an audit record' );
    is( $limiter->snapshot->{degradation_mode},
        'permissive', 'snapshot reports the permissive mode' );
};

subtest 'fail-closed mode denies while the primary store throws' => sub {
    my $telemetry = _telemetry();
    my $audit     = GPForum::Test::Schema->new;
    my $limiter   = _limiter(
        {
            audit     => $audit,
            primary   => GPForum::Test::FailingRateLimitStore->new,
            telemetry => $telemetry,
        }
    );

    my $first = $limiter->check( _limit_input() );
    ok( !$first->{ok}, 'fail-closed mode denies the first request' );
    is( $first->{denied_reason},
        'store_unavailable', 'denial names the unavailable store' );
    is( $first->{store},    'unavailable', 'denial reports no usable store' );
    is( $first->{degraded}, 1,             'denial stays observably degraded' );
    is( $first->{remaining}, 0, 'denial leaves no remaining allowance' );
    is( $first->{limit}, $ACTION_LIMIT, 'denial echoes the requested limit' );
    is( $first->{window_seconds},
        $WINDOW_SECONDS, 'denial echoes the requested window' );
    is( $first->{reset_at_epoch},
        $FAIL_CLOSED_RESET, 'denial offers a bounded retry point' );
    is( $first->{mitigation_hint},
        'retry_after_backoff', 'denial asks the caller to back off' );

    my $retry = $limiter->check( _limit_input() );
    ok( !$retry->{ok}, 'fail-closed mode grants no free pass on retry' );

    is( scalar keys %{ $limiter->fallback_store->buckets },
        0, 'fail-closed mode never touches per-process buckets' );

    my $stats = $limiter->snapshot->{stats};
    is( $stats->{primary_failures},
        $TWO_CHECKS, 'fail-closed mode counts every primary failure' );
    is( $stats->{fallback_used}, 0, 'fail-closed mode uses no fallback store' );
    is( $stats->{blocked},       $TWO_CHECKS, 'both denials count as blocks' );
    is( $stats->{blocked_degraded},
        $TWO_CHECKS, 'both denials count as degraded blocks' );
    is( $stats->{blocked_over_limit},
        0, 'no denial is attributed to the actor exceeding the limit' );
    is( scalar @{ $audit->created_for('AuditLog') },
        0, 'fail-closed denial writes no audit through the failed schema' );

    my $snapshot = $limiter->snapshot;
    is( $snapshot->{degradation_mode},
        'fail_closed', 'snapshot reports the fail-closed mode' );
    is( $snapshot->{fail_closed}, 1, 'snapshot exposes the fail-closed flag' );
    is( $snapshot->{status}, 'degraded',
        'snapshot still reports a degraded limiter' );
};

subtest 'telemetry separates degraded denials from over-limit denials' => sub {
    my $degraded_telemetry = _telemetry();
    my $degraded_limiter   = _limiter(
        {
            primary   => GPForum::Test::FailingRateLimitStore->new,
            telemetry => $degraded_telemetry,
        }
    );
    $degraded_limiter->check( _limit_input() );

    my $degraded_events = $degraded_telemetry->snapshot->{events};
    is( $degraded_events->{rate_limit_fail_closed}{count},
        1, 'fail-closed denial emits its own telemetry event' );
    is( $degraded_events->{rate_limit_fail_closed}{last_metadata}{reason},
        'store_unavailable', 'fail-closed telemetry names the cause' );
    is( $degraded_events->{rate_limit_fail_closed}{last_metadata}{status},
        $HTTP_TOO_MANY, 'fail-closed telemetry keeps the response status' );
    is( $degraded_events->{rate_limit_store_degraded}{count},
        1, 'store degradation telemetry survives fail-closed mode' );
    is( $degraded_events->{rate_limit_hit}{last_metadata}{reason},
        'store_unavailable', 'rate limit hit telemetry names the cause' );
    is( $degraded_events->{rate_limit_hit}{last_metadata}{degraded},
        1, 'rate limit hit telemetry keeps the degraded flag' );

    my $over_limit_telemetry = _telemetry();
    my $over_limit_limiter   = _limiter(
        {
            primary   => _postgresql_store(),
            telemetry => $over_limit_telemetry,
        }
    );
    $over_limit_limiter->check( _limit_input() );
    $over_limit_limiter->check( _limit_input() );

    my $over_limit_events = $over_limit_telemetry->snapshot->{events};
    is( $over_limit_events->{rate_limit_hit}{last_metadata}{reason},
        'over_limit', 'over-limit telemetry names the allowance' );
    is( $over_limit_events->{rate_limit_hit}{last_metadata}{degraded},
        0, 'over-limit telemetry is not degraded' );
    ok(
        !exists $over_limit_events->{rate_limit_fail_closed},
        'over-limit denial emits no fail-closed telemetry'
    );
};

subtest 'degradation policy derives its mode from the environment' => sub {
    my $default =
      GPForum::Service::Operations::RateLimiter::DegradationPolicy->new;
    is( $default->mode, 'fail_closed', 'policy defaults to fail-closed' );
    is( $default->fail_closed, 1,      'default policy fails closed' );
    is( $default->permissive,  0,      'default policy is not permissive' );

    is( _policy_for_environment('development')->permissive,
        1, 'development stays permissive' );
    is( _policy_for_environment('test')->permissive,
        1, 'test stays permissive' );
    is( _policy_for_environment('staging')->fail_closed,
        1, 'staging fails closed' );
    is( _policy_for_environment('production')->fail_closed,
        1, 'production fails closed' );
    is( _policy_for_environment('production-small')->fail_closed,
        1, 'production profiles fail closed' );
    is( _policy_for_environment(undef)->fail_closed,
        1, 'an unknown environment fails closed' );

    is(
        _policy_from_config( GPForum::Config->new( environment => 'staging' ) )
          ->fail_closed,
        1,
        'config without a mode knob falls back to the environment'
    );
    is(
        _policy_from_config(
            GPForum::Config->new( environment => 'development' )
        )->permissive,
        1,
        'development config stays permissive'
    );
    is( _policy_from_config(undef)->fail_closed,
        1, 'a missing config fails closed' );

    my $override = GPForum::Test::RateLimitDegradationConfig->new(
        environment                 => 'production',
        rate_limit_degradation_mode => 'permissive',
    );
    is( _policy_from_config($override)->permissive,
        1, 'an explicit config mode wins over the environment' );

    throws_ok(
        sub {
            return
              GPForum::Service::Operations::RateLimiter::DegradationPolicy
              ->new( mode => 'maybe' );
        },
        qr/unknown [ ] rate [ ] limiter [ ] degradation [ ] mode/msx,
        'an unknown mode fails at wiring time'
    );
};

subtest 'a limiter without a primary store is never degraded' => sub {
    my $limiter = GPForum::Service::Operations::RateLimiter->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
    );

    my $decision = $limiter->check( _limit_input() );
    ok( $decision->{ok}, 'single-store wiring keeps serving' );
    is( $decision->{store}, 'local_memory', 'local memory is authoritative' );
    ok( !$decision->{degraded},
        'local memory decisions are not flagged degraded' );
    is( $limiter->snapshot->{stats}{fallback_used},
        0, 'nothing is counted as a fallback' );
};

done_testing();

sub _limiter {
    my ($input) = @_;

    return GPForum::Service::Operations::RateLimiter->new(
        clock              => GPForum::Test::FixedClock->new,
        degradation_policy => $input->{policy}
          || GPForum::Service::Operations::RateLimiter::DegradationPolicy->new,
        id_service         => GPForum::Test::Id->new,
        primary_store      => $input->{primary},
        schema             => $input->{audit} || GPForum::Test::Schema->new,
        security_telemetry => $input->{telemetry},
    );
}

sub _policy {
    my ($mode) = @_;

    return GPForum::Service::Operations::RateLimiter::DegradationPolicy->new(
        mode => $mode );
}

sub _policy_for_environment {
    my ($environment) = @_;

    return
      GPForum::Service::Operations::RateLimiter::DegradationPolicy
      ->from_environment($environment);
}

sub _policy_from_config {
    my ($config) = @_;

    return
      GPForum::Service::Operations::RateLimiter::DegradationPolicy
      ->from_config($config);
}

sub _postgresql_store {
    return GPForum::Service::Operations::RateLimiter::PostgreSQLStore->new(
        clock  => GPForum::Test::FixedClock->new,
        schema => GPForum::Test::RateLimitSchema->new,
    );
}

sub _telemetry {
    return GPForum::Service::Operations::SecurityTelemetry->new(
        clock => GPForum::Test::FixedClock->new, );
}

sub _limit_input {
    return {
        action         => 'thread.create',
        actor_id       => 'user-1',
        limit          => $ACTION_LIMIT,
        scope          => 'forum_http',
        window_seconds => $WINDOW_SECONDS,
    };
}

1;
