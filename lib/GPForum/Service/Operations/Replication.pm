# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::Replication;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

# PostgreSQL's default max_wal_size: about a checkpoint cycle's worth of WAL.
# An inactive slot holding more than that keeps WAL the primary would
# otherwise have recycled, for a standby that is not reading it.
const my $DEFAULT_MAX_RETAINED_BYTES => 1_073_741_824;

# Every query reads in-memory catalog views, so a scrape costs three short
# round trips and takes no lock.
const my $RECOVERY_SQL => 'SELECT pg_is_in_recovery()';

# Without pg_read_all_stats PostgreSQL hides every column of a walsender but
# its pid and application_name: the row is there, its state and positions are
# null. That role, not pg_monitor: pg_monitor adds pg_read_all_settings, which
# reads the settings only a superuser should -- a standby's primary_conninfo,
# replication password included when one was given.
const my $STANDBYS_SQL => join q{ },
  'SELECT application_name, state, sync_state,',
  'extract(epoch FROM replay_lag)::float8 AS replay_lag_seconds,',
  'pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint AS bytes_behind',
  'FROM pg_stat_replication ORDER BY application_name, pid';

# A slot's retained WAL is measured from where this node's WAL ends: the
# write position on a primary, the replay position on a standby, where
# pg_current_wal_lsn() refuses to answer.
const my %SLOTS_SQL => map {
    $_->[0] => join q{ },
      'SELECT slot_name, slot_type, active, wal_status,',
      "pg_wal_lsn_diff($_->[1], restart_lsn)::bigint AS retained_bytes",
      'FROM pg_replication_slots ORDER BY slot_name'
} (
    [ primary => 'pg_current_wal_lsn()' ],
    [ standby => 'pg_last_wal_replay_lsn()' ]
);

# The age of the last transaction replayed grows on an idle primary too, so
# it is paired with the WAL received and not yet replayed, and with whether a
# WAL receiver is connected at all: a standby cut off from its primary has
# nothing pending either, because it receives nothing. pg_stat_wal_receiver
# has a row only while the receiver is connected, and shows it -- its pid,
# not its details -- to any role.
const my $STANDBY_SQL => join q{ },
  'SELECT extract(epoch FROM now() - pg_last_xact_replay_timestamp())::float8',
  'AS replay_age_seconds,',
'pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())::bigint',
  'AS replay_pending_bytes,',
  'EXISTS (SELECT 1 FROM pg_stat_wal_receiver) AS receiving';

has max_retained_bytes => sub { return $DEFAULT_MAX_RETAINED_BYTES; };

sub default_max_retained_bytes ($class) {
    return $DEFAULT_MAX_RETAINED_BYTES;
}

sub snapshot ( $self, $dbh ) {
    my ($in_recovery) = $dbh->selectrow_array($RECOVERY_SQL);
    my $role = $in_recovery ? 'standby' : 'primary';
    my $snapshot =
      $in_recovery
      ? _standby_position($dbh)
      : _standbys($dbh);

    return {
        %{$snapshot},
        role   => $role,
        slots  => _slots( $dbh, $SLOTS_SQL{$role} ),
        status => 'ok',
    };
}

# Degraded, never failed: a slot nobody reads costs the primary disk, not
# service, and dropping it is an operator's decision (docs/ops/
# standby-and-failover.md). Two cases: an inactive slot retaining more WAL
# than the limit, which will fill the disk if the standby is gone for good,
# and a lost slot, whose standby can no longer catch up at all.
sub slot_report ( $self, $snapshot ) {
    my $limit = $self->max_retained_bytes;
    my @problems;
    for my $slot ( @{ $snapshot->{slots} || [] } ) {
        if ( ( $slot->{wal_status} // q{} ) eq 'lost' ) {
            push @problems,
              "slot $slot->{slot_name} is lost: its standby must be rebuilt";
            next;
        }
        next if $slot->{active};
        next if ( $slot->{retained_bytes} // 0 ) <= $limit;
        push @problems,
          "inactive slot $slot->{slot_name} retains"
          . " $slot->{retained_bytes} bytes of WAL, over $limit";
    }

    return {
        max_retained_bytes => $limit,
        problems           => \@problems,
        role               => $snapshot->{role},
        slots              => $snapshot->{slots} || [],
        status             => @problems ? 'degraded' : 'ok',
    };
}

sub _standbys ($dbh) {
    my @standbys = map {
        {
            application_name   => $_->{application_name},
            bytes_behind       => _number( $_->{bytes_behind} ),
            replay_lag_seconds => _number( $_->{replay_lag_seconds} ),
            state              => $_->{state},
            sync_state         => $_->{sync_state},
        }
    } @{ $dbh->selectall_arrayref( $STANDBYS_SQL, { Slice => {} } ) };

    return {
        standbys                => \@standbys,
        standby_details_visible => ( grep { !defined $_->{state} } @standbys )
        ? 0
        : 1,
    };
}

sub _standby_position ($dbh) {
    my $row = $dbh->selectrow_hashref($STANDBY_SQL) || {};

    return {
        receiving            => $row->{receiving} ? 1 : 0,
        replay_age_seconds   => _number( $row->{replay_age_seconds} ),
        replay_pending_bytes => _number( $row->{replay_pending_bytes} ),
    };
}

sub _slots ( $dbh, $sql ) {
    return [
        map {
            {
                active         => $_->{active} ? 1 : 0,
                retained_bytes => _number( $_->{retained_bytes} ),
                slot_name      => $_->{slot_name},
                slot_type      => $_->{slot_type},
                wal_status     => $_->{wal_status},
            }
        } @{ $dbh->selectall_arrayref( $sql, { Slice => {} } ) }
    ];
}

# DBD::Pg hands numbers back as strings; the metrics are JSON numbers.
sub _number ($value) {
    return if !defined $value;

    return 0 + $value;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::Replication - Replication lag and replication slots, read from PostgreSQL.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $replication = GPForum::Service::Operations::Replication->new(
        max_retained_bytes => 2 * 1024**3 );

    my $snapshot = $replication->snapshot($dbh);
    my $report   = $replication->slot_report($snapshot);

=head1 DESCRIPTION

What ADR 0058 asks to be monitored of replication, as the node the
application is connected to sees it. On a primary: each standby streaming
from it (C<pg_stat_replication>), with its replay lag in seconds and the
bytes of WAL it has not replayed, and each replication slot with the WAL it
keeps. On a standby: how long ago the last transaction was replayed, the
WAL received but not yet replayed, and whether a WAL receiver is connected --
without it, a standby cut off from its primary reads like one whose primary
is idle.

The standby rows need C<pg_read_all_stats>: without it PostgreSQL shows
only their C<application_name>, and C<standby_details_visible> is 0. Grant
that role rather than C<pg_monitor>, which adds C<pg_read_all_settings> and
with it a standby's C<primary_conninfo>.

=head1 SUBROUTINES/METHODS

=head2 snapshot

Takes a DBI handle and returns C<status> (C<ok>), C<role> (C<primary> or
C<standby>) and C<slots>, each with C<slot_name>, C<slot_type>, C<active>
(0 or 1), C<wal_status> and C<retained_bytes>. A primary adds C<standbys>
(C<application_name>, C<state>, C<sync_state>, C<replay_lag_seconds>,
C<bytes_behind>) and C<standby_details_visible>; a standby adds
C<replay_age_seconds>, C<replay_pending_bytes> and C<receiving> (1 while its
WAL receiver is connected, else 0). C<replay_lag_seconds> is
null once a standby has caught up and the primary is idle.

=head2 slot_report

Takes a snapshot and returns C<status>: C<degraded> when an inactive slot
retains more than C<max_retained_bytes> of WAL or a slot is lost, else
C<ok>, with the C<problems> found, the C<slots>, the C<role> and the
limit.

=head2 default_max_retained_bytes

Class method: the limit when none is configured, 1 GiB.

=head1 DIAGNOSTICS

C<snapshot> lets DBI errors through; its callers catch them, so a database
that cannot answer turns the metrics section C<unavailable> and the
readiness check C<degraded>.

=head1 CONFIGURATION AND ENVIRONMENT

C<max_retained_bytes>, 1 GiB by default.

=head1 DEPENDENCIES

L<Mojo::Base>, L<Const::Fast>.

=head1 INCOMPATIBILITIES

PostgreSQL 13 or later, for C<wal_status>.

=head1 BUGS AND LIMITATIONS

Physical and logical slots are judged alike. Cascading standbys are seen
only from the standby they stream from.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
