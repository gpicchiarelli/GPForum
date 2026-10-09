# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use DBI;
use English    qw(-no_match_vars);
use File::Path qw(remove_tree);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use Test::More;
use Time::HiRes qw(sleep);

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Schema;
use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Service::Operations::Readiness;
use GPForum::Service::Operations::Replication;

our $VERSION = '0.001';

const my $POLL_TRIES   => 100;
const my $POLL_SECONDS => 0.1;
const my $NO_LIMIT     => 1_099_511_627_776;
const my @TOOLS        => qw(initdb pg_ctl pg_basebackup);
const my $STANDBY_NAME => 'gpforum_standby';

# ADR 0058 on a real primary and standby, built as script/standby-drill
# builds them: two throwaway clusters, the standby cloned through a slot, and
# a second slot whose standby never comes. Needs the PostgreSQL server tools
# on PATH; it touches no other server.
my @missing = grep { !_on_path($_) } @TOOLS;
if (@missing) {
    plan skip_all => "PostgreSQL server tools not on PATH: @missing";
}

# Removed by END once the clusters are stopped: File::Temp's own cleanup ran
# first, and left two postmasters running on deleted data directories.
my $workdir = tempdir( 'gpforum-replication-XXXXXX', TMPDIR => 1 );
my %cluster =
  map { $_ => File::Spec->catdir( $workdir, $_ ) } qw(primary standby);
my %port = ( primary => _free_port(), standby => _free_port() );

_run(
    'initdb', '-D',   $cluster{primary}, '--no-locale',
    '-E',     'UTF8', '--auth=trust',    '-U',
    'gpforum'
);
_append( "$cluster{primary}/postgresql.conf",
        "wal_level = replica\nmax_wal_senders = 5\nmax_replication_slots = 5\n"
      . "shared_buffers = 16MB\n" );
_append( "$cluster{primary}/pg_hba.conf",
    "host replication gpforum 127.0.0.1/32 trust\n" );
_start('primary');

my $admin = _dbh( 'primary', 'gpforum' );
$admin->do("SELECT pg_create_physical_replication_slot('$STANDBY_NAME')");
$admin->do(q{SELECT pg_create_physical_replication_slot('gone_standby', true)});

# The application's role, granted what the runbook says: pg_read_all_stats.
$admin->do('CREATE ROLE monitor LOGIN');
$admin->do('GRANT pg_read_all_stats TO monitor');
$admin->do('CREATE ROLE plain LOGIN');

_run( 'pg_basebackup', '-h', '127.0.0.1', '-p', $port{primary}, '-U', 'gpforum',
    '-D', $cluster{standby}, '-Fp', '-Xs', '-R', '-S', $STANDBY_NAME );
_start( 'standby', "-c cluster_name=$STANDBY_NAME" );

# A write the standby has replayed, so it has a last replayed transaction,
# and WAL the gone standby's slot has to keep.
$admin->do('CREATE TABLE probe AS SELECT g FROM generate_series(1, 20000) g');
my $standby_admin = _dbh( 'standby', 'gpforum' );
ok(
    _eventually(
        sub {
            return
              scalar $standby_admin->selectrow_array(
                q{SELECT to_regclass('probe') IS NOT NULL});
        }
    ),
    'the standby replays the primary\'s writes'
);
ok(
    _eventually(
        sub {
            return
              scalar $admin->selectrow_array(
                    q{SELECT count(*) FROM pg_stat_replication}
                  . q{ WHERE state = 'streaming'} );
        }
    ),
    'and streams from it'
);

my $replication = GPForum::Service::Operations::Replication->new;
my $primary     = $replication->snapshot( _dbh( 'primary', 'monitor' ) );
is( $primary->{role}, 'primary', 'the primary knows it is one' );
my ($standby_row) = @{ $primary->{standbys} };
is( $standby_row->{application_name},
    $STANDBY_NAME, 'and lists the standby streaming from it' );
is( $standby_row->{state}, 'streaming', 'with its state' );
ok( defined $standby_row->{bytes_behind} && $standby_row->{bytes_behind} >= 0,
    'and the bytes it has not replayed' );
is( $primary->{standby_details_visible},
    1, 'which pg_read_all_stats lets the role read' );

my %slot = map { $_->{slot_name} => $_ } @{ $primary->{slots} };
is( $slot{$STANDBY_NAME}{active}, 1, 'the standby\'s slot is active' );
is( $slot{gone_standby}{active},  0, 'the other slot is not' );
cmp_ok( $slot{gone_standby}{retained_bytes},
    '>', 0, 'and keeps the WAL written since it was made' );

my $hidden = $replication->snapshot( _dbh( 'primary', 'plain' ) );
is( $hidden->{standby_details_visible},
    0, 'a role without it is told the details are hidden' );
is( $hidden->{standbys}[0]{state}, undef, 'PostgreSQL hides the state' );

my $standby = $replication->snapshot( _dbh( 'standby', 'plain' ) );
is( $standby->{role}, 'standby', 'the standby knows it is one' );
ok(
    defined $standby->{replay_age_seconds}
      && $standby->{replay_age_seconds} >= 0,
    'and how long ago it replayed a transaction'
);
ok(
    defined $standby->{replay_pending_bytes}
      && $standby->{replay_pending_bytes} >= 0,
    'and the WAL it has received and not replayed'
);
is( $standby->{receiving}, 1,
    'and that it is receiving, which a role without the grant can read' );

# pg_monitor would also bring pg_read_all_settings, and with it the settings
# only a superuser reads: a standby's primary_conninfo, which holds the
# replication password when one was given to pg_basebackup -R. The grant the
# runbook recommends shows the standbys and not that.
my $standby_monitor = _dbh( 'standby', 'monitor' );
my $conninfo_read   = 0;
try {
    $standby_monitor->selectrow_array('SHOW primary_conninfo');
    $conninfo_read = 1;
}
catch ($error) {
    $conninfo_read = 0;
};
is( $conninfo_read, 0,
    'the role the runbook recommends cannot read the primary_conninfo' );

# The endpoint and readiness, through the application's own schema.
my $metrics = GPForum::Service::Operations::MetricsSnapshot->new(
    schema => _schema( 'primary', 'monitor' ) )->collect->{replication};
is( $metrics->{standbys}[0]{application_name},
    $STANDBY_NAME, '/metrics reports the standby' );

my $over = _slot_check( 'primary', 1 );
is( $over->{status}, 'degraded',
    'readiness degrades on the slot nobody reads' );
is_deeply( [ map { /slot [ ] (\S+)/msx } @{ $over->{report}{problems} } ],
    ['gone_standby'],
    'and blames only that slot, not the one its standby is reading' );
is( _slot_check( 'primary', $NO_LIMIT )->{status},
    'ok', 'under the limit it is ok' );
is( _slot_check( 'standby', 1 )->{status},
    'ok', 'and a standby without slots of its own is ok' );

# A standby whose primary is gone has nothing pending -- it receives nothing
# -- and its replay age grows as an idle primary's would. Only receiving
# tells the two apart.
_run( 'pg_ctl', '-D', $cluster{primary}, '-m', 'fast', '-w', 'stop' );
$cluster{primary_started} = 0;
my $standby_plain = _dbh( 'standby', 'plain' );
ok(
    _eventually(
        sub {
            my $receiving = $replication->snapshot($standby_plain)->{receiving};
            return defined $receiving && $receiving == 0;
        }
    ),
    'a standby cut off from its primary says it is not receiving'
);

done_testing();

sub _slot_check {
    my ( $name, $limit ) = @_;

    my $report = GPForum::Service::Operations::Readiness->new(
        config                              => GPForum::Config->new,
        environment                         => 'test',
        replication_slot_max_retained_bytes => $limit,
        schema                              => _schema( $name, 'monitor' ),
    )->check;
    my ($check) =
      grep { $_->{name} eq 'replication_slots' } @{ $report->{checks} };

    return $check;
}

sub _dsn {
    my ($name) = @_;

    return "dbi:Pg:dbname=postgres;host=127.0.0.1;port=$port{$name}";
}

sub _dbh {
    my ( $name, $user ) = @_;

    return DBI->connect( _dsn($name), $user, q{},
        { AutoCommit => 1, PrintError => 0, RaiseError => 1 } );
}

sub _schema {
    my ( $name, $user ) = @_;

    return GPForum::Schema->connect( _dsn($name), $user, q{},
        { AutoCommit => 1, PrintError => 0, RaiseError => 1 } );
}

# Unix sockets are off: the temporary directory's path is longer than a
# socket path may be.
sub _start {
    my ( $name, @options ) = @_;

    _run(
        'pg_ctl', '-D',
        $cluster{$name},
        '-l',
        "$cluster{$name}.log",
        '-w', '-o',
        join( q{ },
            "-p $port{$name}",
            q{-c unix_socket_directories=''},
            '-c listen_addresses=127.0.0.1',
            @options ),
        'start'
    );
    $cluster{"${name}_started"} = 1;

    return;
}

sub _run {
    my (@command) = @_;

    open my $saved, '>&', \*STDOUT            or _bail('dup stdout');
    open STDOUT,    '>',  File::Spec->devnull or _bail('silence stdout');
    my $status = system @command;
    open STDOUT, '>&', $saved or _bail('restore stdout');
    close $saved or _bail('close the saved stdout');
    if ( $status != 0 ) {
        BAIL_OUT("@command failed");
    }

    return;
}

sub _bail {
    my ($what) = @_;

    BAIL_OUT("could not $what: $OS_ERROR");

    return;
}

sub _append {
    my ( $file, $text ) = @_;

    open my $handle, '>>', $file or BAIL_OUT("could not open $file");
    print {$handle} $text or BAIL_OUT("could not write $file");
    close $handle         or BAIL_OUT("could not close $file");

    return;
}

sub _eventually {
    my ($probe) = @_;

    for ( 1 .. $POLL_TRIES ) {
        return 1 if $probe->();
        sleep $POLL_SECONDS;
    }

    return 0;
}

sub _free_port {
    my $socket = IO::Socket::INET->new(
        Listen    => 1,
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
    ) or BAIL_OUT("no free port: $OS_ERROR");
    my $port = $socket->sockport;
    close $socket or BAIL_OUT('could not release the port');

    return $port;
}

sub _on_path {
    my ($tool) = @_;

    return grep { -x File::Spec->catfile( $_, $tool ) } File::Spec->path;
}

# Stops the clusters however the test ends, then removes them. The exit
# status is the test's: system would otherwise leave pg_ctl's in
# $CHILD_ERROR, which END returns.
END {
    local $CHILD_ERROR = $CHILD_ERROR;
    for my $name (qw(standby primary)) {
        next if !$cluster{"${name}_started"};
        system 'pg_ctl', '-D', $cluster{$name}, '-m', 'immediate', '-s', 'stop';
    }
    if ( defined $workdir ) {
        remove_tree($workdir);
    }
}

1;
