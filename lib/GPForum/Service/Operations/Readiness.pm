# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::Readiness;

use Const::Fast;
use Time::HiRes qw(time);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Config;
use GPForum::Infrastructure::Storage;
use GPForum::Service::Clock;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::OSPreflight;
use GPForum::Service::Operations::PartitionLifecycle;
use GPForum::Service::Operations::Profile;
use GPForum::Service::Operations::QueryBudget;
use GPForum::Service::Operations::Replication;

our $VERSION = '0.001';

const my $MILLISECONDS_PER_SECOND => 1000;
const my $MAX_ERROR_LENGTH        => 240;

# The system antivirus (ADR 0108), or undef when scanning is off.
has antivirus      => undef;  # optional: without one the check reports disabled
has cache          => undef;  # optional: without one the check reports local
has clock          => sub { return GPForum::Service::Clock->new; };
has config         => undef;                 # optional: from the environment
has environment    => 'development';
has glifistore_url => sub { return q{}; };

# The WAL an inactive replication slot may keep before readiness degrades.
# Undef takes the configuration's, then Replication's default (1 GiB).
has replication_slot_max_retained_bytes => undef;    # optional: the config's
has runtime        => undef;    # optional: without one the runtime check fails
has runtime_policy => undef;    # optional: without one its check is skipped
has schema         => undef;    # optional: without one the database checks fail

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
    query_budget_drift   => 'docs/PERFORMANCE.md#query-budgets',
    replication_slots    => 'docs/ops/standby-and-failover.md#watch-the-lag',
    runtime              => 'docs/OS_RUNTIME_ENFORCEMENT.md',
    runtime_enforcement  => 'docs/OS_RUNTIME_ENFORCEMENT.md',
    shared_cache         => 'docs/DEPLOYMENT.md#glifistore-optional',
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
        $self->_replication_slot_check,
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

    try {
        my $dbh = $self->schema->storage->dbh;
        $dbh->selectrow_array('SELECT 1');
    }
    catch ($error) {
        return _failed_check( 'database', $started, $error );
    };

    return _ok_check( 'database', $started );
}

sub _os_preflight_check ($self) {
    my $started   = time;
    my $preflight = GPForum::Service::Operations::OSPreflight->new(
        runtime => $self->runtime,
        %{ $self->runtime ? $self->runtime->os_preflight_settings || {} : {} },
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

sub _resultset_check ( $self, $name ) {
    my $started = time;

    try {
        my $probe = $self->probe_resultset($name);
        if ( $probe && $probe->can('next') ) {
            $probe->next;
        }
        elsif ( $probe && $probe->can('single') ) {
            $probe->single;
        }
    }
    catch ($error) {
        return _failed_check( lc $name, $started, $error );
    };

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
        my $status =
          $self->_config->requires_secure_transport ? 'degraded' : 'ok';
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

# GlifiStore is optional everywhere (D2): without one each process keeps its
# own cache, which is all a single host needs, and the check is ok with a
# note saying so. One configured that does not answer leaves the process on
# its local cache, degraded.
sub _shared_cache_check ($self) {
    my $started = time;
    my $url     = $self->glifistore_url;
    if ( !defined $url || !length $url ) {
        return {
            %{ _mode_check( 'shared_cache', $started, 'ok', 'disabled' ) },
            note => GPForum::Service::I18N::CliCatalog->new->text(
                'readiness.shared_cache_local',
                { variable => 'GPFORUM_GLIFISTORE_URL' }
            ),
        };
    }

    my $cache = $self->cache;

    # A LocalCache has no shared tier to ping: it is the local fallback.
    if ( $cache && $cache->can('ping') && $cache->ping ) {
        return _mode_check( 'shared_cache', $started, 'ok', 'shared' );
    }

    return _mode_check( 'shared_cache', $started, 'degraded',
        'local-fallback' );
}

# Degraded, never failed, when partitions run short or rows spill into a
# DEFAULT partition (3.7): writes still land, and taking the node out of
# service would not create a partition.
sub _partition_horizon_check ($self) {
    return $self->_catalog_check(
        'partition_horizon',
        sub ($dbh) {
            return
              GPForum::Service::Operations::PartitionLifecycle->new
              ->horizon_report( $dbh, $self->clock->now_epoch );
        }
    );
}

# A report read from the catalog, degraded when it cannot be read. A schema
# without a DBI handle -- a test double -- has no catalog to read.
sub _catalog_check ( $self, $name, $read ) {
    my $started = time;
    my $storage = GPForum::Infrastructure::Storage->storage_of( $self->schema );
    if ( !$storage || !$storage->can('dbh_do') ) {
        return _mode_check( $name, $started, 'ok', 'no catalog' );
    }

    my ( $report, $failure );
    try {
        $report = $storage->dbh_do( sub ( $, $dbh ) { return $read->($dbh); } );
    }
    catch ($error) {
        $failure = $error;
    };
    if ( !$report ) {
        return {
            %{ _failed_check( $name, $started, $failure ) },
            status => 'degraded',
        };
    }

    return {
        %{ _ok_check( $name, $started ) },
        report => $report,
        status => $report->{status},
    };
}

# Degraded, never failed, when an inactive slot keeps more WAL than the limit
# or a slot is lost (ADR 0058): the primary still serves, and taking it out
# of service would not drop the slot.
sub _replication_slot_check ($self) {
    return $self->_catalog_check(
        'replication_slots',
        sub ($dbh) {
            my $replication = GPForum::Service::Operations::Replication->new(
                max_retained_bytes => $self->_replication_slot_limit );

            return $replication->slot_report( $replication->snapshot($dbh) );
        }
    );
}

# The attribute's limit, else one a configuration object answers for --
# GPForum::Config carries no such setting; a test's double does -- else
# Replication's default.
sub _replication_slot_limit ($self) {
    return $self->replication_slot_max_retained_bytes
      if defined $self->replication_slot_max_retained_bytes;

    my $config = $self->_config;
    if ( $config->can('replication_slot_max_retained_bytes') ) {
        my $limit = $config->replication_slot_max_retained_bytes;
        return $limit if defined $limit;
    }

    return
      GPForum::Service::Operations::Replication->default_max_retained_bytes;
}

sub _mode_check ( $name, $started, $status, $mode ) {
    my $check = _ok_check( $name, $started );
    $check->{status} = $status;
    $check->{mode}   = $mode;
    return $check;
}

sub _profile_check ($self) {
    my $started = time;
    my $result =
      GPForum::Service::Operations::Profile->new->evaluate( $self->_config );

    return {
        latency_ms => int( ( time - $started ) * $MILLISECONDS_PER_SECOND ),
        name       => 'operational_profile',
        report     => $result,
        status     => $result->{ok} ? 'ok' : 'fail',
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
    my $report;
    try {
        $report =
          GPForum::Service::Operations::QueryBudget->new(
            schema => $self->schema )->drift_report;
    }
    catch ($error) {
        return _failed_check( 'query_budget_drift', $started, $error );
    };

    return {
        name       => 'query_budget_drift',
        status     => $report->{status} eq 'ok' ? 'ok' : 'fail',
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
the shared cache (ok with a note when no GlifiStore is configured, which a
single host does not need), the antivirus and the partition horizon are
healthy, the
configuration fits its operational profile, and no replication slot is lost
or keeps more WAL for an absent standby than the limit
(C<replication_slot_max_retained_bytes>, 1 GiB by default). A check that
cannot pass without the node being useless fails; one the forum can live
without for a while is degraded. Every check that is not ok names its
runbook.

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

Never dies: a check that throws is reported failed with its error, or
degraded for the partition horizon and the replication slots, which the forum
can serve without.

=head1 CONFIGURATION AND ENVIRONMENT

Reads L<GPForum::Config>, and C<replication_slot_max_retained_bytes> from a
configuration object that offers it (GPForum::Config has no such setting);
the attribute of the same name overrides it. The C<shared_cache> check's
C<note> follows the operator's language
(L<GPForum::Service::I18N::CliCatalog>).

=head1 DEPENDENCIES

L<GPForum::Service::Operations::PartitionLifecycle>,
L<GPForum::Service::Operations::Replication>,
L<GPForum::Service::Operations::QueryBudget>,
L<GPForum::Service::Operations::Profile>,
L<GPForum::Infrastructure::Storage>.

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
