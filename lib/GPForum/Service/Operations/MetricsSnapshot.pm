# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::MetricsSnapshot;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;
use Time::HiRes qw(time);

use GPForum::Service::Operations::OSPreflight;
use GPForum::Service::Operations::QueryBudget;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $MILLISECONDS_PER_SECOND => 1000;

has clock               => sub { return GPForum::Service::Clock->new; };
has db_query_stats      => undef;
has local_caches        => sub { return []; };
has schema              => undef;
has rate_limiter        => undef;
has realtime_hub        => undef;
has realtime_supervisor => undef;
has security_telemetry  => undef;
has projection_trackers => sub { return []; };
has query_budget =>
  sub { return GPForum::Service::Operations::QueryBudget->new; };
has runtime        => undef;
has runtime_policy => undef;
has started_at     => sub { return time; };

sub collect ($self) {
    my $runtime = $self->runtime;

    return {
        generated_at => $self->clock->now_iso8601,
        process      => {
            pid            => $PROCESS_ID,
            uptime_seconds => int( time - $self->started_at ),
        },
        runtime             => $runtime ? $runtime->as_hash : {},
        os                  => $self->_runtime_os_snapshot,
        os_features         => $self->_runtime_os_features,
        os_sockets          => $self->_runtime_os_sockets,
        os_processes        => $self->_runtime_os_processes,
        os_preflight        => $self->_runtime_os_preflight,
        runtime_enforcement => $self->_runtime_enforcement,
        local_caches        => $self->_local_caches,
        realtime            => $self->_realtime,
        realtime_listener   => $self->_realtime_listener,
        rate_limits         => $self->_rate_limits,
        security            => $self->_security,
        projections         => $self->_projections,
        db_query_stats      => $self->_db_query_stats,
        query_budgets       => $self->_query_budgets,
        query_budget_drift  => $self->_query_budget_drift,
        database            => $self->_database,
        outbox              => $self->_outbox,
    };
}

sub _runtime_os_snapshot ($self) {
    return {} if !$self->runtime;

    return $self->runtime->os_profile->snapshot;
}

sub _runtime_os_features ($self) {
    return {} if !$self->runtime;

    return $self->runtime->os_profile->feature_snapshot(
        $self->runtime->os_feature_settings );
}

sub _runtime_os_sockets ($self) {
    return {} if !$self->runtime;

    return $self->runtime->os_profile->socket_snapshot(
        $self->runtime->os_feature_settings );
}

sub _runtime_os_processes ($self) {
    return {} if !$self->runtime;

    return $self->runtime->os_profile->process_snapshot(
        $self->runtime->os_feature_settings );
}

sub _runtime_os_preflight ($self) {
    return {} if !$self->runtime;

    return GPForum::Service::Operations::OSPreflight->new(
        runtime => $self->runtime,
        $self->_os_preflight_settings,
    )->check;
}

sub _runtime_enforcement ($self) {
    return {} if !$self->runtime_policy;

    return $self->runtime_policy->report;
}

sub _os_preflight_settings ($self) {
    return () if !$self->runtime;

    my $settings = $self->runtime->os_preflight_settings || {};

    return %{$settings};
}

sub _realtime ($self) {
    return {} if !$self->realtime_hub;

    return $self->realtime_hub->snapshot;
}

sub _realtime_listener ($self) {
    return {} if !$self->realtime_supervisor;

    return $self->realtime_supervisor->snapshot;
}

sub _local_caches ($self) {
    return [
        grep { defined }
        map  { $_->snapshot } @{ $self->local_caches }
    ];
}

sub _rate_limits ($self) {
    return {} if !$self->rate_limiter;

    my $snapshot = $self->rate_limiter->snapshot;
    my $stats    = $snapshot->{stats} || {};

    $snapshot->{rate_limit_allowed} =
      defined $stats->{allowed} ? $stats->{allowed} : 0;
    $snapshot->{rate_limit_blocked} =
      defined $stats->{blocked} ? $stats->{blocked} : 0;
    $snapshot->{degraded_rate_limiter_active} =
      _degraded_rate_limiter_active( $snapshot, $stats );

    return $snapshot;
}

sub _security ($self) {
    return {} if !$self->security_telemetry;

    return $self->security_telemetry->snapshot;
}

sub _projections ($self) {
    return [
        grep { defined }
        map  { $_->observe_lag } @{ $self->projection_trackers }
    ];
}

sub _db_query_stats ($self) {
    return {} if !$self->db_query_stats;

    return $self->db_query_stats->snapshot;
}

sub _query_budgets ($self) {
    return $self->query_budget->snapshot;
}

sub _query_budget_drift ($self) {
    return {} if !$self->schema;

    my $report = eval {
        return GPForum::Service::Operations::QueryBudget->new(
            schema => $self->schema )->drift_report;
    };

    return {} if !$report;

    return $report;
}

sub _database ($self) {
    return {} if !$self->schema;

    my $started = time;
    my $ok      = eval {
        my $storage = $self->schema->storage;
        my $dbh     = $storage->dbh;
        $dbh->selectrow_array('SELECT 1');
        1;
    };

    return {
        ready_latency_ms =>
          int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
        status => $ok ? 'ok' : 'fail',
    };
}

# Outbox rows due for another attempt.
# Public so the query-plan evidence EXPLAINs what actually runs.
sub retry_backlog_resultset ($self) {
    return $self->schema->resultset('OutboxMessage')->search_rs(
        {
            status          => { -in  => [ 'pending', 'failed' ] },
            next_attempt_at => { '<=' => $self->clock->now_iso8601 },
        }
    );
}

sub _outbox ($self) {
    return {} if !$self->schema;

    my $snapshot = eval {
        my $outbox = $self->schema->resultset('OutboxMessage');
        return {
            pending => $outbox->search_rs( { status => 'pending' } )->count,
            failed  => $outbox->search_rs( { status => 'failed' } )->count,
            retry_backlog => $self->retry_backlog_resultset->count,
            dead_letters  =>
              $self->schema->resultset('DeadLetter')->search_rs( {} )->count,
        };
    };

    return {} if !$snapshot;

    return $snapshot;
}

sub _degraded_rate_limiter_active ( $snapshot, $stats ) {
    return 1 if ( $snapshot->{status}     || q{} ) eq 'degraded';
    return 1 if ( $stats->{fallback_used} || 0 ) > 0;

    return 0;
}

1;
