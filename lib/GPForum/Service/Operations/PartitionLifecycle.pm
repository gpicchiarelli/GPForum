package GPForum::Service::Operations::PartitionLifecycle;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $EPOCH_YEAR_OFFSET => 1900;
const my $MONTHS_PER_YEAR   => 12;
const my $POLICY_VERSION    => 1;
const my $SECONDS_PER_DAY   => 86_400;
const my @PARTITIONED_TABLES => qw(
  audit_log
  event_log
  notifications
);
const my %NEXT_STATE => (
    planned  => 'created',
    created  => 'detached',
    detached => 'archived',
    archived => 'dropped',
);

sub partitioned_tables {
    return [@PARTITIONED_TABLES];
}

sub policy_version {
    return $POLICY_VERSION;
}

sub plan_window {
    my ( $self, $input ) = @_;

    my $horizon = $input->{horizon_months} || 1;
    my @months  = $self->_month_starts( $input->{now_epoch}, $horizon );
    my @plans;
    for my $month (@months) {
        push @plans, $self->_plans_for_month($month);
    }

    return \@plans;
}

sub next_state {
    my ( undef, $state ) = @_;

    if ( !$state || !exists $NEXT_STATE{$state} ) {
        return;
    }

    return $NEXT_STATE{$state};
}

sub retention_due {
    my ( $self, $input ) = @_;

    my $cutoff = $self->_cutoff_iso($input);
    my @due;
    for my $row ( @{ $input->{partitions} || [] } ) {
        if ( $self->_is_retention_due( $row, $cutoff ) ) {
            push @due, $self->_recommendation($row);
        }
    }

    return \@due;
}

sub restore_evidence {
    my ( $self, $input ) = @_;

    my $counts  = $self->_state_counts( $input->{partitions} || [] );
    my $created = $counts->{created} || 0;

    return {
        ok               => $created ? 1 : 0,
        partition_counts => $counts,
        policy_version   => $POLICY_VERSION,
        restore_ready    => $created ? 1 : 0,
        tables           => $self->partitioned_tables,
    };
}

sub _plans_for_month {
    my ( $self, $month ) = @_;

    my @plans;
    for my $table ( @{ $self->partitioned_tables } ) {
        push @plans, $self->_plan_row( $table, $month );
    }

    return @plans;
}

sub _plan_row {
    my ( undef, $table, $month ) = @_;

    my $next = _shift_ym( $month, 1 );

    return {
        partition_name =>
          sprintf( '%s_%04d_%02d', $table, $month->{year}, $month->{month} ),
        range_end   => _iso_month_start($next),
        range_start => _iso_month_start($month),
        state       => 'planned',
        table_name  => $table,
    };
}

sub _month_starts {
    my ( undef, $epoch, $count ) = @_;

    my $origin = _ym($epoch);
    my @starts;
    my $offset = 0;
    while ( $offset < $count ) {
        push @starts, _shift_ym( $origin, $offset );
        $offset += 1;
    }

    return @starts;
}

sub _cutoff_iso {
    my ( undef, $input ) = @_;

    my $days  = $input->{retention_days} || 0;
    my $epoch = ( $input->{now_epoch} || 0 ) - ( $days * $SECONDS_PER_DAY );

    return _iso_from_epoch($epoch);
}

sub _is_retention_due {
    my ( undef, $row, $cutoff ) = @_;

    if ( ( $row->{state} || q{} ) ne 'created' ) {
        return 0;
    }

    return ( $row->{range_end} || q{} ) le $cutoff ? 1 : 0;
}

sub _recommendation {
    my ( $self, $row ) = @_;

    return { %{$row},
        recommended_state => $self->next_state( $row->{state} ), };
}

sub _state_counts {
    my ( undef, $rows ) = @_;

    my %counts = (
        archived => 0,
        created  => 0,
        detached => 0,
        dropped  => 0,
        planned  => 0,
    );
    for my $row ( @{$rows} ) {
        my $state = $row->{state} || 'planned';
        if ( exists $counts{$state} ) {
            $counts{$state} += 1;
        }
    }

    return \%counts;
}

sub _ym {
    my ($epoch) = @_;

    my ( undef, undef, undef, undef, $month, $year ) = gmtime $epoch;

    return {
        month => $month + 1,
        year  => $year + $EPOCH_YEAR_OFFSET,
    };
}

sub _shift_ym {
    my ( $origin, $delta ) = @_;

    my $index =
      ( $origin->{year} * $MONTHS_PER_YEAR ) +
      ( $origin->{month} - 1 ) +
      $delta;

    return {
        month => ( $index % $MONTHS_PER_YEAR ) + 1,
        year  => int( $index / $MONTHS_PER_YEAR ),
    };
}

sub _iso_month_start {
    my ($ym) = @_;

    return sprintf '%04d-%02d-01T00:00:00Z', $ym->{year}, $ym->{month};
}

sub _iso_from_epoch {
    my ($epoch) = @_;

    my ( $sec, $minute, $hour, $day, $month, $year ) = gmtime $epoch;

    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
      $year + $EPOCH_YEAR_OFFSET,
      $month + 1, $day, $hour, $minute, $sec;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::PartitionLifecycle - Partition retention policy.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $plans = $lifecycle->plan_window(
        { now_epoch => time, horizon_months => 3 } );

=head1 DESCRIPTION

Versions the operational lifecycle for range-partitioned C<event_log>,
C<audit_log>, and C<notifications> tables. It plans monthly partitions,
recommends retention transitions, and emits restore evidence. It does not
execute DDL; PostgreSQL partition creation stays with operators and
migrations.

=head1 SUBROUTINES/METHODS

=head2 partitioned_tables

Returns the tables covered by this policy.

=head2 policy_version

Returns the lifecycle policy version.

=head2 plan_window

Plans monthly partitions from the current month through the requested horizon.

=head2 next_state

Returns the next registry state for C<planned>, C<created>, C<detached>, or
C<archived>.

=head2 retention_due

Returns created partitions whose range has aged past the retention cutoff, with
a recommended C<detached> state.

=head2 restore_evidence

Summarizes registry rows for restore and archival evidence.

=head1 DIAGNOSTICS

This module does not throw its own exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

Horizon and retention days come from L<GPForum::Service::Operations::Profile>.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

DDL execution and C<partition_registry> persistence are operator-owned. This
boundary versions the policy and evidence contract only.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
