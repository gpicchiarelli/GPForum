# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::Readiness;

use strict;
use warnings;

use Const::Fast;
use English     qw(-no_match_vars);
use Time::HiRes qw(time);
use Mojo::Base -base, -signatures;

use GPForum::Config;
use GPForum::Service::Clock;
use GPForum::Service::Operations::OSPreflight;
use GPForum::Service::Operations::PartitionLifecycle;
use GPForum::Service::Operations::Profile;
use GPForum::Service::Operations::QueryBudget;

our $VERSION = '0.001';

const my $MILLISECONDS_PER_SECOND => 1000;
const my $MAX_ERROR_LENGTH        => 240;

# The system antivirus (ADR 0108), or undef when scanning is off.
has antivirus      => undef;
has cache          => undef;
has clock          => sub { return GPForum::Service::Clock->new; };
has config         => undef;
has environment    => 'development';
has glifistore_url => sub { return q{}; };
has runtime        => undef;
has runtime_policy => undef;
has schema         => undef;

# Where the operator goes when a check is not ok: every check readiness can
# return has a runbook, and a check that is degraded or failed carries its
# path, so a warning on /health/ready says what to do about it. The missing
# tables point at the migrations, which create them.
const my $MIGRATIONS_RUNBOOK => 'docs/DEPLOYMENT.md#postgresql-baseline';
const my %RUNBOOK => (
    antivirus            => 'docs/ops/antivirus.md',
    database             => 'docs/DEPLOYMENT.md#postgresql-baseline',
    endpointquerybudget  => $MIGRATIONS_RUNBOOK,
    eventlog             => $MIGRATIONS_RUNBOOK,
    operational_profile  => 'docs/architecture/operational-profiles.md',
    os_preflight         => 'docs/OS_RUNTIME_ENFORCEMENT.md',
    outboxmessage        => $MIGRATIONS_RUNBOOK,
    partition_horizon    => 'docs/ops/partition-maintenance.md',
    projectiongeneration => $MIGRATIONS_RUNBOOK,
    query_budget_drift   => 'docs/QUERY_BUDGET_POLICY.md',
    runtime              => 'docs/OS_RUNTIME_ENFORCEMENT.md',
    runtime_enforcement  => 'docs/OS_RUNTIME_ENFORCEMENT.md',
    shared_cache         => 'docs/DEPLOYMENT.md#glifistore-required-l2',
);

# Every check name readiness can return, with its runbook.
sub runbooks ($class) {
    return {%RUNBOOK};
}

sub check ($self) {
    my $started = time;
    my @checks  = (
        $self->_db_check,
        $self->_runtime_check,
        $self->_os_preflight_check,
        $self->_runtime_enforcement_check,
        $self->_resultset_check('EventLog'),
        $self->_resultset_check('OutboxMessage'),
        $self->_resultset_check('ProjectionGeneration'),
        $self->_resultset_check('EndpointQueryBudget'),
        $self->_query_budget_drift_check,
        $self->_shared_cache_check,
        $self->_antivirus_check,
        $self->_partition_horizon_check,
        $self->_profile_check,
    );

    for my $check (@checks) {
        next if ( $check->{status}               // q{} ) eq 'ok';
        next if !exists $RUNBOOK{ $check->{name} // q{} };
        $check->{runbook} = $RUNBOOK{ $check->{name} };
    }

    return {
        status      => _overall_status( \@checks ),
        checks      => \@checks,
        environment => $self->environment,
        runtime     => $self->runtime ? $self->runtime->as_hash : {},
        timestamp   => $self->clock->now_iso8601,
        latency_ms  => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
    };
}

sub _runtime_check ($self) {
    my $started = time;
    my $runtime = $self->runtime;
    return _failed_check( 'runtime', $started, 'runtime profile unavailable' )
      if !$runtime;

    my $profile = $runtime->as_hash;
    return _failed_check( 'runtime', $started, 'OS profile unavailable' )
      if !$profile->{os} || !$profile->{os}{name};

    return _ok_check( 'runtime', $started );
}

sub _db_check ($self) {
    my $started = time;

    eval {
        my $storage = $self->schema->storage;
        my $dbh     = $storage->dbh;
        $dbh->selectrow_array('SELECT 1');
        1;
    } or return _failed_check( 'database', $started, $EVAL_ERROR );

    return _ok_check( 'database', $started );
}

sub _os_preflight_check ($self) {
    my $started   = time;
    my $preflight = GPForum::Service::Operations::OSPreflight->new(
        runtime => $self->runtime,
        $self->_os_preflight_settings,
    )->check;

    return {
        name       => 'os_preflight',
        status     => $preflight->{status},
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
        checks     => $preflight->{checks},
    };
}

sub _runtime_enforcement_check ($self) {
    return _ok_check( 'runtime_enforcement', time )
      if !$self->runtime_policy;

    my $started = time;
    my $check   = $self->runtime_policy->readiness_check;
    return {
        name       => $check->{name},
        status     => $check->{status},
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
        report     => $check->{report},
    };
}

sub _os_preflight_settings ($self) {
    return () if !$self->runtime;

    my $settings = $self->runtime->os_preflight_settings || {};

    return %{$settings};
}

sub _resultset_check ( $self, $name ) {
    my $started = time;

    eval {
        my $probe = $self->probe_resultset($name);
        if ( $probe && $probe->can('next') ) {
            $probe->next;
        }
        elsif ( $probe && $probe->can('single') ) {
            $probe->single;
        }
        1;
    } or return _failed_check( lc $name, $started, $EVAL_ERROR );

    return _ok_check( lc $name, $started );
}

# The one-row read readiness makes of each table.
# Public so the query-plan evidence EXPLAINs what actually runs.
sub probe_resultset ( $self, $name ) {
    return $self->schema->resultset($name)->search_rs( {}, { rows => 1 } );
}

# Degraded, never failed: an antivirus that cannot scan holds uploads back --
# they stay pending and unserved -- and the rest of the forum works. Scanning
# turned off is ok where it is the default and degraded where it is not.
sub _antivirus_check ($self) {
    my $started = time;
    if ( !$self->antivirus ) {
        my $status = $self->_expects_antivirus ? 'degraded' : 'ok';
        return _mode_check( 'antivirus', $started, $status, 'format-check' );
    }

    return {
        name => 'antivirus',
        %{
            $self->antivirus->within_request->health( $self->clock->now_epoch )
        },
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
    };
}

sub _expects_antivirus ($self) {
    return $self->_config->requires_secure_transport ? 1 : 0;
}

sub _shared_cache_check ($self) {
    my $started = time;
    if ( !_has_text( $self->glifistore_url ) ) {
        return $self->_missing_shared_cache($started);
    }
    if ( $self->_shared_cache_reachable ) {
        return _mode_check( 'shared_cache', $started, 'ok', 'shared' );
    }

    return _mode_check( 'shared_cache', $started, 'degraded',
        'local-fallback' );
}

sub _missing_shared_cache ( $self, $started ) {
    if ( $self->_requires_shared_cache ) {
        return _failed_check( 'shared_cache', $started,
            'glifistore_url is required' );
    }

    return _mode_check( 'shared_cache', $started, 'ok', 'disabled' );
}

sub _requires_shared_cache ($self) {
    if ( $self->config ) {
        return $self->config->requires_glifistore;
    }

    return GPForum::Config->environment_requires_glifistore(
        $self->environment );
}

sub _shared_cache_reachable ($self) {
    my $cache = $self->cache;
    if ( !$cache || !$cache->can('ping') ) {
        return 0;
    }

    return $cache->ping ? 1 : 0;
}

# Degraded, never failed, when partitions run short or rows spill into a
# DEFAULT partition (3.7): writes still land, and taking the node out of
# service would not create a partition. A schema without a DBI handle -- a
# test double -- has no catalog to read.
sub _partition_horizon_check ($self) {
    my $started = time;
    my $storage =
        $self->schema && $self->schema->can('storage')
      ? $self->schema->storage
      : undef;
    if ( !$storage || !$storage->can('dbh_do') ) {
        return _mode_check( 'partition_horizon', $started, 'ok', 'no catalog' );
    }

    my $report = eval {
        return $storage->dbh_do(
            sub ( $, $dbh ) {
                return
                  GPForum::Service::Operations::PartitionLifecycle->new
                  ->horizon_report( $dbh, $self->clock->now_epoch );
            }
        );
    };
    if ( !$report ) {
        my $check = _failed_check( 'partition_horizon', $started, $EVAL_ERROR );
        $check->{status} = 'degraded';
        return $check;
    }

    return {
        %{ _ok_check( 'partition_horizon', $started ) },
        report => $report,
        status => $report->{status},
    };
}

sub _mode_check ( $name, $started, $status, $mode ) {
    my $check = _ok_check( $name, $started );
    $check->{status} = $status;
    $check->{mode}   = $mode;
    return $check;
}

sub _has_text ($value) {
    return defined $value && length $value ? 1 : 0;
}

sub _profile_check ($self) {
    my $started = time;
    my $result =
      GPForum::Service::Operations::Profile->new->evaluate( $self->_config );
    if ( $result->{ok} ) {
        return {
            latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
            name       => 'operational_profile',
            report     => $result,
            status     => 'ok',
        };
    }

    return {
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
        name       => 'operational_profile',
        report     => $result,
        status     => 'fail',
    };
}

sub _config ($self) {
    if ( $self->config ) {
        return $self->config;
    }

    return GPForum::Config->new;
}

sub _query_budget_drift_check ($self) {
    my $started = time;
    my $report  = eval {
        return GPForum::Service::Operations::QueryBudget->new(
            schema => $self->schema )->drift_report;
    } or return _failed_check( 'query_budget_drift', $started, $EVAL_ERROR );

    return _failed_query_budget_check( $started, $report )
      if $report->{status} ne 'ok';

    return {
        name       => 'query_budget_drift',
        status     => 'ok',
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
        report     => $report,
    };
}

sub _failed_query_budget_check ( $started, $report ) {
    return {
        name       => 'query_budget_drift',
        status     => 'fail',
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
        report     => $report,
    };
}

sub _ok_check ( $name, $started ) {
    return {
        name       => $name,
        status     => 'ok',
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
    };
}

sub _failed_check ( $name, $started, $error ) {
    return {
        name       => $name,
        status     => 'fail',
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
        error      => _compact_error($error),
    };
}

sub _overall_status ($checks) {
    for my $check ( @{$checks} ) {
        return 'fail' if $check->{status} eq 'fail';
    }

    for my $check ( @{$checks} ) {
        return 'degraded' if $check->{status} eq 'degraded';
    }

    return 'ok';
}

sub _compact_error ($error) {
    if ( !defined $error ) {
        $error = q{};
    }
    $error =~ s/\s+/ /gmsx;
    $error =~ s/\A\s+|\s+\z//gmsx;

    return substr $error, 0, $MAX_ERROR_LENGTH;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::Readiness - The checks behind /health/ready.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $report = GPForum::Service::Operations::Readiness->new(
        config  => $config,
        runtime => $runtime,
        schema  => $schema,
    )->check;

=head1 DESCRIPTION

Whether this node should take traffic: the database answers, the runtime and
OS posture hold, the tables the forum needs exist, the query budgets match,
the shared cache, the antivirus and the partition horizon are healthy, and the
configuration fits its operational profile. A check that cannot pass without
the node being useless fails; one the forum can live without for a while is
degraded. Every check that is not ok names its runbook.

=head1 SUBROUTINES/METHODS

=head2 check

Runs every check and returns the overall status, the checks, the environment,
the runtime, a timestamp and the latency.

=head2 runbooks

Every check name readiness can return, mapped to the runbook a degraded or
failed check carries in its C<runbook> field.

=head2 probe_resultset

The one-row query a table check runs.

=head1 DIAGNOSTICS

Never dies: a check that throws is reported failed with its error.

=head1 CONFIGURATION AND ENVIRONMENT

Reads L<GPForum::Config>.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::PartitionLifecycle>,
L<GPForum::Service::Operations::QueryBudget>,
L<GPForum::Service::Operations::Profile>.

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
