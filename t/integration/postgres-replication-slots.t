# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use DBI;
use English qw(-no_match_vars);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Service::Operations::Readiness;
use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

const my $LARGE_LIMIT => 1_099_511_627_776;

# The slot to drop at the end, once it exists.
my $dropping;

# END does not run when a signal kills the test -- Ctrl-C under prove -- and
# the slot outlived it, keeping the server's WAL. A signal ends the test
# through die instead, so END drops the slot.
local $SIG{INT}  = \&_interrupted;
local $SIG{TERM} = \&_interrupted;

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all =>
      'set GPFORUM_DATABASE_DSN to run the replication slot test';
}

# ADR 0058 against PostgreSQL's own catalog: a slot whose standby never
# connects keeps the primary's WAL, /metrics shows how much, and readiness
# degrades once it is over the limit. The slot is the server's, not the test
# database's, so it is dropped however the test ends.
my $database        = GPForum::Test::PgDatabase->fresh;
my $dbh             = $database->dbh;
my ($can_replicate) = $dbh->selectrow_array(
'SELECT rolsuper OR rolreplication FROM pg_roles WHERE rolname = current_user'
);
if ( !$can_replicate ) {
    plan skip_all => 'the test role may not create replication slots';
}
my ($wal_level) = $dbh->selectrow_array('SHOW wal_level');
if ( $wal_level eq 'minimal' ) {
    plan skip_all => 'wal_level minimal has no replication slots';
}

_drop_stale_slots($dbh);
my $slot = sprintf 'gpforum_t_slot_%d', $PROCESS_ID;
$dbh->selectrow_array( 'SELECT pg_create_physical_replication_slot(?, true)',
    undef, $slot );
$dropping = $slot;

# WAL the slot has to keep: the standby it waits for never reads it.
$dbh->do(
'CREATE TABLE replication_probe AS SELECT g FROM generate_series(1, 50000) g'
);

my $metrics = GPForum::Service::Operations::MetricsSnapshot->new(
    schema => $database->schema )->collect->{replication};
is( $metrics->{status}, 'ok',      'the metrics read the replication views' );
is( $metrics->{role},   'primary', 'of a server that is not in recovery' );
my ($reported) = grep { $_->{slot_name} eq $slot } @{ $metrics->{slots} };
ok( $reported, 'the slot is reported' );
is( $reported->{active}, 0, 'inactive: no standby reads it' );
cmp_ok( $reported->{retained_bytes},
    '>', 0, 'and it retains the WAL written since' );
is( $reported->{wal_status}, 'reserved', 'still within max_wal_size' );

my $over = _slot_check(1);
is( $over->{status}, 'degraded',
    'readiness degrades on an inactive slot over the limit' );
ok( ( grep { /\Q$slot\E/msx } @{ $over->{report}{problems} } ),
    'and names the slot' );
is( _slot_check($LARGE_LIMIT)->{status}, 'ok', 'under the limit it is ok' );

_drop_slot();
my ($remaining) =
  $dbh->selectrow_array(
    'SELECT count(*) FROM pg_replication_slots WHERE slot_name = ?',
    undef, $slot );
is( $remaining, 0, 'the slot is gone' );

done_testing();

sub _slot_check {
    my ($limit) = @_;

    my $report = GPForum::Service::Operations::Readiness->new(
        environment                         => 'test',
        replication_slot_max_retained_bytes => $limit,
        schema                              => $database->schema,
    )->check;
    my ($check) =
      grep { $_->{name} eq 'replication_slots' } @{ $report->{checks} };

    return $check;
}

# A run killed outright (SIGKILL) still leaves its slot: one named for a
# process that no longer exists is dropped before this run makes its own. A
# live process's is left alone -- another run of this test may be using it.
sub _drop_stale_slots {
    my ($handle) = @_;

    my $stale = $handle->selectcol_arrayref(
            q{SELECT slot_name FROM pg_replication_slots}
          . q{ WHERE NOT active AND slot_name ~ '^gpforum_t_slot_[0-9]+$'} );
    for my $name ( @{$stale} ) {
        my ($pid) = $name =~ /(\d+)\z/msx;
        next if _process_exists($pid);
        $handle->selectrow_array( 'SELECT pg_drop_replication_slot(?)',
            undef, $name );
    }

    return;
}

# kill 0 fails with EPERM for another user's live process.
sub _process_exists {
    my ($pid) = @_;

    return 1 if kill 0, $pid;

    return $OS_ERROR{EPERM} ? 1 : 0;
}

sub _interrupted {
    my ($signal) = @_;

    die "interrupted by SIG$signal\n";
}

# The slot is dropped when the test ends, passed or not: a slot left behind
# keeps the server's WAL until its disk fills.
sub _drop_slot {
    return if !$dropping;

    my $admin = DBI->connect(
        GPForum::Test::PgDatabase->admin_dsn,
        $ENV{GPFORUM_DATABASE_USER},
        $ENV{GPFORUM_DATABASE_PASSWORD},
        { AutoCommit => 1, PrintError => 0, RaiseError => 1 }
    );
    $admin->do(
        'SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots'
          . ' WHERE slot_name = ?',
        undef, $dropping
    );
    $admin->disconnect;
    $dropping = undef;

    return;
}

END {
    local $EVAL_ERROR = undef;
    eval { _drop_slot(); 1 } or diag "could not drop the slot: $EVAL_ERROR";
}

1;
