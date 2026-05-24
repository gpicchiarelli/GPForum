package GPForum::Service::Operations::MetricsSnapshot;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;
use Time::HiRes qw(time);

use GPForum::Service::Operations::OSPreflight;
use GPForum::Service::Operations::QueryBudget;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $MILLISECONDS_PER_SECOND => 1000;

has clock               => sub { return GPForum::Service::Clock->new; };
has local_caches        => sub { return []; };
has schema              => undef;
has rate_limiter        => undef;
has realtime_hub        => undef;
has security_telemetry  => undef;
has projection_trackers => sub { return []; };
has query_budget =>
  sub { return GPForum::Service::Operations::QueryBudget->new; };
has runtime        => undef;
has runtime_policy => undef;
has started_at     => sub { return time; };

sub collect {
    my ($self) = @_;
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
        rate_limits         => $self->_rate_limits,
        security            => $self->_security,
        projections         => $self->_projections,
        query_budgets       => $self->_query_budgets,
        query_budget_drift  => $self->_query_budget_drift,
        database            => $self->_database,
        outbox              => $self->_outbox,
    };
}

sub _runtime_os_snapshot {
    my ($self) = @_;

    return {} if !$self->runtime;

    return $self->runtime->os_profile->snapshot;
}

sub _runtime_os_features {
    my ($self) = @_;

    return {} if !$self->runtime;

    return $self->runtime->os_profile->feature_snapshot(
        $self->runtime->os_feature_settings );
}

sub _runtime_os_sockets {
    my ($self) = @_;

    return {} if !$self->runtime;

    return $self->runtime->os_profile->socket_snapshot(
        $self->runtime->os_feature_settings );
}

sub _runtime_os_processes {
    my ($self) = @_;

    return {} if !$self->runtime;

    return $self->runtime->os_profile->process_snapshot(
        $self->runtime->os_feature_settings );
}

sub _runtime_os_preflight {
    my ($self) = @_;

    return {} if !$self->runtime;

    return GPForum::Service::Operations::OSPreflight->new(
        runtime => $self->runtime,
        $self->_os_preflight_settings,
    )->check;
}

sub _runtime_enforcement {
    my ($self) = @_;

    return {} if !$self->runtime_policy;

    return $self->runtime_policy->report;
}

sub _os_preflight_settings {
    my ($self) = @_;

    return () if !$self->runtime;

    my $settings = $self->runtime->os_preflight_settings || {};

    return %{$settings};
}

sub _realtime {
    my ($self) = @_;

    return {} if !$self->realtime_hub;

    return $self->realtime_hub->snapshot;
}

sub _local_caches {
    my ($self) = @_;

    return [
        grep { defined }
        map  { $_->snapshot } @{ $self->local_caches }
    ];
}

sub _rate_limits {
    my ($self) = @_;

    return {} if !$self->rate_limiter;

    return $self->rate_limiter->snapshot;
}

sub _security {
    my ($self) = @_;

    return {} if !$self->security_telemetry;

    return $self->security_telemetry->snapshot;
}

sub _projections {
    my ($self) = @_;

    return [
        grep { defined }
        map  { $_->observe_lag } @{ $self->projection_trackers }
    ];
}

sub _query_budgets {
    my ($self) = @_;

    return $self->query_budget->snapshot;
}

sub _query_budget_drift {
    my ($self) = @_;

    return {} if !$self->schema;

    my $report = eval {
        return GPForum::Service::Operations::QueryBudget->new(
            schema => $self->schema )->drift_report;
    };

    return {} if !$report;

    return $report;
}

sub _database {
    my ($self) = @_;

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

sub _outbox {
    my ($self) = @_;

    return {} if !$self->schema;

    my $pending = eval {
        my $outbox = $self->schema->resultset('OutboxMessage');
        my $search = $outbox->search( { status => 'pending' } );

        return $search->count;
    };

    return {} if !defined $pending;

    return { pending => $pending };
}

1;
