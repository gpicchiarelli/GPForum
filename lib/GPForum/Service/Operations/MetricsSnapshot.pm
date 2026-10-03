# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::MetricsSnapshot;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed);
use Time::HiRes  qw(time);

use GPForum::Service::Operations::OSPreflight;
use GPForum::Service::Operations::QueryBudget;
use GPForum::Service::Operations::Replication;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $MILLISECONDS_PER_SECOND => 1000;
const my $MAX_ERROR_LENGTH        => 240;

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
has replication =>
  sub { return GPForum::Service::Operations::Replication->new; };
has runtime        => undef;
has runtime_policy => undef;
has started_at     => sub { return time; };

# Its counters are the process's (a per-request dispatcher's would die with
# the request), so the one built for this scrape reads what every request's
# counted. Without it a badge that failed after a write was counted and
# never reported.
has notification_dispatcher => undef;

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
        notifications       => $self->_notifications,
        rate_limits         => $self->_rate_limits,
        security            => $self->_security,
        projections         => $self->_projections,
        db_query_stats      => $self->_db_query_stats,
        query_budgets       => $self->_query_budgets,
        query_budget_drift  => $self->_query_budget_drift,
        database            => $self->_database,
        outbox              => $self->_outbox,
        replication         => $self->_replication,
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

# A dispatcher that keeps no counters (a stand-in for one) reports none,
# rather than failing the scrape.
sub _notifications ($self) {
    my $dispatcher = $self->notification_dispatcher;
    return {} if !blessed $dispatcher || !$dispatcher->can('snapshot');

    return $dispatcher->snapshot;
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
        my $by_status = $self->_outbox_status_counts;
        return {
            pending       => $by_status->{pending} // 0,
            failed        => $by_status->{failed}  // 0,
            retry_backlog => $self->retry_backlog_resultset->count,
            dead_letters  => $self->schema->resultset('DeadLetter')->count,
        };
    };

    return {} if !$snapshot;

    return $snapshot;
}

# Pending and failed in one grouped statement. Two counts that differed only
# in their bind value were the same statement sent twice on every scrape:
# the duplicate the query budget forbids.
sub _outbox_status_counts ($self) {
    my $grouped = $self->schema->resultset('OutboxMessage')->search_rs(
        { status => { -in => [ 'pending', 'failed' ] } },
        {
            select   => [ 'status', { count => q{*} } ],
            as       => [ 'status', 'messages' ],
            group_by => ['status'],
        }
    );

    return { map { $_->[0] => $_->[1] } $grouped->cursor->all };
}

# ADR 0058: replication lag is monitored. Read on every scrape -- three
# catalog queries -- and guarded like the database section, so a node that
# cannot read the replication views reports it here instead of failing the
# whole snapshot.
sub _replication ($self) {
    return {} if !$self->schema;

    my $snapshot = eval {
        return $self->replication->snapshot( $self->schema->storage->dbh );
    };
    return $snapshot if $snapshot;

    return {
        error  => _compact_error($EVAL_ERROR),
        status => 'unavailable',
    };
}

sub _compact_error ($error) {
    $error //= q{};
    $error =~ s/\s+/ /gmsx;
    $error =~ s/\A\s+|\s+\z//gmsx;

    return substr $error, 0, $MAX_ERROR_LENGTH;
}

sub _degraded_rate_limiter_active ( $snapshot, $stats ) {
    return 1 if ( $snapshot->{status}     || q{} ) eq 'degraded';
    return 1 if ( $stats->{fallback_used} || 0 ) > 0;

    return 0;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::MetricsSnapshot - The process, runtime and database snapshot behind the metrics endpoint.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $metrics = GPForum::Service::Operations::MetricsSnapshot->new(
        runtime                 => $runtime,
        runtime_policy          => $runtime_policy,
        schema                  => $schema,
        db_query_stats          => $db_query_stats,
        realtime_hub            => $realtime_hub,
        notification_dispatcher => $notification_dispatcher,
        rate_limiter            => $rate_limiter,
        security_telemetry      => $security_telemetry,
        local_caches            => [$local_cache],
    );

    my $snapshot = $metrics->collect;

=head1 DESCRIPTION

Gathers, in one hash, what the operations metrics endpoint reports: the
process id and uptime, the runtime and its OS profile (snapshot, features,
sockets, processes and preflight check), runtime enforcement, local caches,
the realtime hub and its listener supervisor, the notification
dispatcher's badge failures, rate limits, security telemetry, projection
lag, database query statistics, query budgets and their drift, database
readiness, the outbox backlog and replication (ADR 0058). Each collaborator
is optional: a section whose collaborator is not set comes back empty, and
so does the notifications section when the dispatcher has no C<snapshot>.

The database section times a C<SELECT 1>; the outbox, query budget drift and
replication sections are guarded too, so a database that cannot answer turns
them empty, C<fail> or C<unavailable> rather than failing the whole snapshot.
The replication section is L<GPForum::Service::Operations::Replication/snapshot>:
on a primary each standby's replay lag and bytes behind and each slot's
retained WAL, on a standby the age of the last replayed transaction. The rate limit section
adds C<rate_limit_allowed>, C<rate_limit_blocked> and
C<degraded_rate_limiter_active>, which is 1 when the limiter reports
C<degraded> or has used its fallback store.

=head1 SUBROUTINES/METHODS

=head2 collect

Returns the snapshot hash reference with the keys C<generated_at>,
C<process> (C<pid>, C<uptime_seconds> since C<started_at>), C<runtime>,
C<os>, C<os_features>, C<os_sockets>, C<os_processes>, C<os_preflight>,
C<runtime_enforcement>, C<local_caches>, C<realtime>,
C<realtime_listener>, C<notifications> (the notification dispatcher's
L<GPForum::Service::Notification::Dispatcher/snapshot>: C<badge_failures>
and C<last_badge_error>), C<rate_limits>, C<security>, C<projections>,
C<db_query_stats>, C<query_budgets>, C<query_budget_drift>, C<database>
(C<status> C<ok> or C<fail>, and C<ready_latency_ms>), C<outbox>
(C<pending>, C<failed>, C<retry_backlog>, C<dead_letters>) and
C<replication> (the replication snapshot, or C<status> C<unavailable> and the
C<error>).

=head2 retry_backlog_resultset

Returns the resultset of outbox messages that are C<pending> or C<failed>
and due for another attempt (C<next_attempt_at> not after now). It is public
so the query-plan evidence EXPLAINs the query the outbox section counts.
Needs C<schema>.

=head1 DIAGNOSTICS

The database, outbox, query budget drift and replication sections catch
their own errors. Errors from the other collaborators' snapshots propagate from
C<collect>. C<retry_backlog_resultset> dies without a C<schema>.

=head1 CONFIGURATION AND ENVIRONMENT

None read here; the bootstrap passes the runtime and its policy.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::OSPreflight>,
L<GPForum::Service::Operations::QueryBudget>,
L<GPForum::Service::Operations::Replication>,
L<GPForum::Service::Clock>, L<Scalar::Util>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
