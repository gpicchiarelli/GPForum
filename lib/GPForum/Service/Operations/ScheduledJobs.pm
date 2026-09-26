# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::ScheduledJobs;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Service::Attachment::Scanner;
use GPForum::Service::Clock;
use GPForum::Service::Operations::PartitionLifecycle;
use GPForum::Service::Operations::Profile;
use GPForum::Service::Operations::RetentionStore;

our $VERSION = '0.001';

const my @JOB_NAMES => qw(
  sessions
  identity_tokens
  rate_limit_buckets
  outbox_messages
  dead_letters
  attachments
  attachment_scans
  attachment_backfill
  partitions
);
const my $DEFAULT_RETENTION_DAYS => 30;
const my $DEFAULT_RESCAN_LIMIT   => 100;
const my %JOB_METHOD => (
    attachment_backfill => 'backfill_unscanned_uploads',
    attachment_scans    => 'rescan_pending_uploads',
    attachments         => 'cleanup_orphans',
    dead_letters        => 'purge_dead_letters',
    identity_tokens     => 'purge_identity_tokens',
    outbox_messages     => 'purge_outbox_messages',
    partitions          => 'partition_evidence',
    rate_limit_buckets  => 'purge_rate_limit_buckets',
    sessions            => 'purge_sessions',
);

has attachment_scanner  => undef;
has attachment_store    => undef;
has clock               => sub { return GPForum::Service::Clock->new; };
has identity_store      => undef;
has partition_lifecycle => sub {
    return GPForum::Service::Operations::PartitionLifecycle->new;
};
has profile         => undef;
has retention_store => sub {
    my ($self) = @_;

    return GPForum::Service::Operations::RetentionStore->new(
        clock  => $self->clock,
        schema => $self->schema,
    );
};
has schema => undef;

sub from_controller ( $class, $controller ) {
    return $class->new(
        attachment_scanner => GPForum::Service::Attachment::Scanner->new(
            antivirus => $controller->gp_antivirus,
            storage   => $controller->gp_attachment_storage,
            store     => $controller->gp_attachment_store,
        ),
        attachment_store => $controller->gp_attachment_store,
        clock            => $controller->gp_clock,
        identity_store   => $controller->gp_identity_store,
        profile          => $class->_profile_for($controller),
        schema           => $controller->gp_schema,
    );
}

sub job_names {
    return [@JOB_NAMES];
}

# ok is true only when every job that reports ok did: a timer whose job
# failed -- an antivirus that cannot be reached, a file that cannot be read --
# must not look like a run that succeeded.
sub run ( $self, $input ) {
    $input ||= {};
    my %summary = ( ok => 1 );
    for my $name ( @{ $self->selected_jobs($input) } ) {
        my $result = $self->run_job( $name, $input );
        $summary{$name} = $result;
        if ( ref $result eq 'HASH' && exists $result->{ok} && !$result->{ok} ) {
            $summary{ok} = 0;
        }
    }

    return \%summary;
}

sub selected_jobs ( $self, $input ) {
    if ( $input->{jobs} && @{ $input->{jobs} } ) {
        return $input->{jobs};
    }

    return $self->job_names;
}

sub run_job ( $self, $name, $input ) {
    if ( !exists $JOB_METHOD{$name} ) {
        return { error => 'unknown_job', ok => 0 };
    }

    my $method = $JOB_METHOD{$name};
    return $self->$method($input);
}

sub purge_sessions ( $self, $input ) {
    return $self->retention_store->purge_sessions($input);
}

sub purge_identity_tokens ( $self, $input ) {
    return $self->retention_store->purge_identity_tokens($input);
}

sub purge_rate_limit_buckets ( $self, $input ) {
    return $self->retention_store->purge_rate_limit_buckets($input);
}

sub purge_outbox_messages ( $self, $input ) {
    return $self->retention_store->purge_outbox_messages($input);
}

sub purge_dead_letters ( $self, $input ) {
    return $self->retention_store->purge_dead_letters($input);
}

sub cleanup_orphans ( $self, $input ) {
    if ( !$self->attachment_store ) {
        return _unavailable();
    }

    return $self->attachment_store->cleanup_orphans($input);
}

# Uploads left pending because the antivirus could not answer, scanned again
# oldest first. ADR 0108.
sub rescan_pending_uploads ( $self, $input ) {
    return $self->_scan_batch( $input, 'pending_scan_ids', 'scan' );
}

# Files served on a format check alone -- uploaded before scanning, or while
# it was off -- put through the antivirus, oldest first. Nothing to do when
# scanning is off.
sub backfill_unscanned_uploads ( $self, $input ) {
    my $scanner = $self->attachment_scanner;
    if ( $scanner && !$scanner->antivirus ) {
        return { ok => 1, scanned => 0, skipped => 'scanning is off' };
    }

    return $self->_scan_batch( $input, 'unscanned_clean_ids', 'backfill' );
}

# Starts only when the antivirus answers -- otherwise every file would fail the
# same way, each after its own timeout -- and goes on past a file that fails
# by itself, so one bad file cannot hold back the rest.
sub _scan_batch ( $self, $input, $select, $action ) {
    my $scanner = $self->attachment_scanner;
    if ( !$scanner || !$self->attachment_store ) {
        return _unavailable();
    }
    if ( !$scanner->antivirus_available ) {
        return { error => 'antivirus unavailable', ok => 0, scanned => 0 };
    }

    my ( $scanned, @errors ) = (0);
    my $ids =
      $self->attachment_store->$select( $input->{limit}
          || $DEFAULT_RESCAN_LIMIT );
    for my $attachment_id ( @{$ids} ) {
        if ( eval { $scanner->$action($attachment_id); 1 } ) {
            $scanned++;
            next;
        }
        my $error = _first_line($EVAL_ERROR);
        push @errors, "$attachment_id: $error";
        $self->attachment_store->record_scan_failure( $attachment_id, $error );
    }

    return {
        ok      => @errors ? 0 : 1,
        scanned => $scanned,
        ( @errors ? ( errors => \@errors ) : () ),
    };
}

sub partition_evidence ( $self, $input ) {
    my $partitions = $self->_registry_rows;
    my $lifecycle  = $self->partition_lifecycle;

    return {
        ok             => 1,
        plans          => $self->_plan_window($input),
        policy_version => $lifecycle->policy_version,
        retention_due  => $self->_retention_due( $input, $partitions ),
        restore        =>
          $lifecycle->restore_evidence( { partitions => $partitions } ),
    };
}

sub _plan_window ( $self, $input ) {
    return $self->partition_lifecycle->plan_window(
        {
            horizon_months => $self->_horizon_months($input),
            now_epoch      => $self->clock->now_epoch,
        }
    );
}

sub _retention_due ( $self, $input, $partitions ) {
    return $self->partition_lifecycle->retention_due(
        {
            now_epoch      => $self->clock->now_epoch,
            partitions     => $partitions,
            retention_days => $self->_retention_days($input),
        }
    );
}

sub _horizon_months ( $self, $input ) {
    if ( $input && $input->{horizon_months} ) {
        return $input->{horizon_months};
    }

    return $self->_profile_value('partition_horizon_months') || 1;
}

sub _retention_days ( $self, $input ) {
    if ( $input && $input->{retention_days} ) {
        return $input->{retention_days};
    }

    return $self->_profile_value('event_retention_days')
      || $DEFAULT_RETENTION_DAYS;
}

sub _profile_value ( $self, $field ) {
    my $profile = $self->profile;
    my $undefined;
    return $undefined if !$profile;

    return $profile->{$field};
}

sub _registry_rows ($self) {
    my $resultset = $self->_registry_resultset;
    if ( !$resultset ) {
        return [];
    }

    return [ map { $self->_registry_hash($_) }
          $self->_resultset_rows($resultset) ];
}

sub _registry_resultset ($self) {
    my $undefined;
    return $undefined if !$self->schema;

    return $self->schema->resultset('PartitionRegistry');
}

sub _resultset_rows ( $, $resultset ) {
    if ( $resultset->can('items') ) {
        return $resultset->items;
    }

    return $resultset->all;
}

sub _registry_hash ( $self, $row ) {
    return {
        partition_name => $self->_column( $row, 'partition_name' ),
        range_end      => $self->_column( $row, 'range_end' ),
        state          => $self->_column( $row, 'state' ),
        table_name     => $self->_column( $row, 'table_name' ),
    };
}

sub _column ( $, $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

sub _profile_for ( $, $controller ) {
    my $config = $controller->gp_config;
    if ( !$config ) {
        my $undefined;
        return $undefined;
    }

    return GPForum::Service::Operations::Profile->new->get(
        GPForum::Service::Operations::Profile->new->name_for_environment(
            $config->environment
        )
    );
}

sub _first_line ($error) {
    my ($line) = split /\n/msx, defined $error ? "$error" : q{};
    $line =~ s/\s+ at \s+ \S+ \s+ line \s+ \d+ [.]? \z//msx;

    return $line;
}

sub _unavailable {
    return {
        deleted => 0,
        ok      => 1,
        skipped => 'unavailable',
    };
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::ScheduledJobs - Operational job runner.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $summary = $jobs->run( { limit => 100 } );

=head1 DESCRIPTION

Runs the operational jobs GPForum does not execute during request handling:
bounded retention deletes, attachment orphan cleanup, and partition
policy/evidence. It does not execute C<CREATE TABLE ... PARTITION OF> and
does not persist partition registry rows.

=head1 SUBROUTINES/METHODS

=head2 from_controller

Builds a runner from a Mojolicious controller's existing helpers.

=head2 job_names

Returns the canonical job list.

=head2 run

Runs the selected jobs and returns a summary hash.

=head2 selected_jobs

Returns C<jobs> from the input, or every canonical job.

=head2 run_job

Dispatches one named job.

=head2 purge_sessions

Deletes stale session rows through L<GPForum::Service::Operations::RetentionStore>.

=head2 purge_identity_tokens

Deletes stale identity tokens.

=head2 purge_rate_limit_buckets

Deletes expired rate-limit windows.

=head2 purge_outbox_messages

Deletes completed outbox rows past the grace window.

=head2 purge_dead_letters

Deletes aged dead-letter rows.

=head2 cleanup_orphans

Calls L<GPForum::Service::Attachment::Store/cleanup_orphans>.

=head2 rescan_pending_uploads

Scans again the uploads left pending because the antivirus could not answer
(ADR 0108), oldest first. Does not start while the antivirus is unreachable;
goes on past a file that fails by itself.

=head2 backfill_unscanned_uploads

Puts files served on a format check alone through the antivirus, oldest
first; skipped when scanning is off.

=head2 partition_evidence

Calls L<GPForum::Service::Operations::PartitionLifecycle> plan, retention,
and restore evidence only.

=head1 DIAGNOSTICS

Unknown job names return C<unknown_job>. Missing attachment storage is
skipped rather than thrown.

=head1 CONFIGURATION AND ENVIRONMENT

Horizon and event retention days come from L<GPForum::Service::Operations::Profile>
when a controller is available.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<GPForum::Service::Clock>,
L<GPForum::Service::Operations::PartitionLifecycle>,
L<GPForum::Service::Operations::Profile>,
L<GPForum::Service::Operations::RetentionStore>, and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Operators still apply partition DDL from the planned windows. FreeBSD hosts
still need an operator crontab because this runner is oneshot.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
