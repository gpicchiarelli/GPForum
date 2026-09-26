# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PostgresHarness;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use DBI;
use English qw(-no_match_vars);
use IO::Handle;
use JSON::MaybeXS qw(decode_json encode_json);
use POSIX         qw(_exit);

use GPForum::Command::Migrate;
use GPForum::Command::PerformanceSeed;
use GPForum::Config;
use GPForum::Schema;

our $VERSION = '0.001';

const my $WORKER_COUNT => 2;

sub create_database {
    my ($admin_dsn) = @_;

    if ( $admin_dsn !~ /dbname=[^;]+/msx ) {
        croak 'GPFORUM_DATABASE_DSN must name a database with dbname=';
    }

    my $name      = sprintf 'gpforum_conc_%d_%d', $PROCESS_ID, time;
    my $admin_dbh = connect_dbi($admin_dsn);
    $admin_dbh->do( 'CREATE DATABASE ' . $admin_dbh->quote_identifier($name) );

    ( my $dsn = $admin_dsn ) =~ s/dbname=[^;]+/dbname=$name/msx;

    return {
        admin_dbh => $admin_dbh,
        dbh       => connect_dbi($dsn),
        dsn       => $dsn,
        name      => $name,
    };
}

sub drop_database {
    my ($database_info) = @_;

    $database_info->{dbh}->disconnect;
    my $admin_dbh = $database_info->{admin_dbh};
    $admin_dbh->do( 'DROP DATABASE IF EXISTS '
          . $admin_dbh->quote_identifier( $database_info->{name} )
          . ' WITH (FORCE)' );
    $admin_dbh->disconnect;

    return;
}

sub connect_dbi {
    my ($dsn) = @_;

    return DBI->connect(
        $dsn,
        $ENV{GPFORUM_DATABASE_USER},
        $ENV{GPFORUM_DATABASE_PASSWORD},
        { AutoCommit => 1, PrintError => 0, RaiseError => 1 },
    );
}

sub prepare_database {
    my $migrate =
      quietly( sub { GPForum::Command::Migrate->new->run('--apply') } );
    my $seed = quietly(
        sub {
            GPForum::Command::PerformanceSeed->new->run( '--profile', 'small' );
        }
    );

    return { migrate => $migrate, seed => $seed };
}

sub connect_schema {
    return GPForum::Schema->connect_from_config(
        GPForum::Config->from_environment );
}

sub race {
    my ($worker) = @_;

    my $pipes = _open_barrier_pipes();
    my @children =
      map { _spawn_race_worker( $worker, $_, $pipes ) } 0 .. $WORKER_COUNT - 1;
    _release_workers($pipes);

    return map { _read_worker_outcome($_) } @children;
}

sub worker_count {
    return $WORKER_COUNT;
}

sub count_rows {
    my ( $dbh, $table, $query ) = @_;

    my @columns = sort keys %{$query};
    my $sql     = 'SELECT COUNT(*) FROM ' . $table;
    if (@columns) {
        $sql .= ' WHERE ' . join ' AND ', map { "$_ = ?" } @columns;
    }

    my ($count) = $dbh->selectrow_array( $sql, undef, @{$query}{@columns} );

    return $count;
}

sub row_value {
    my ( $row, $key ) = @_;

    if ( !defined $row ) {
        return;
    }
    if ( ref $row eq 'HASH' ) {
        return $row->{$key};
    }
    if ( ref $row && $row->can($key) ) {
        return $row->$key;
    }

    return;
}

# The plan of the statement a resultset would execute, with sequential scans
# disabled. That is a usability test, not a cost comparison: if PostgreSQL
# still picks a sequential scan ("Disabled: true") no index can answer the
# query at all, whatever the table's size. EXPLAINs the resultset itself, so
# the plan is of what the application runs, not of a transcription.
sub plan_without_seqscan {
    my ( $dbh, $resultset ) = @_;

    my ( $sql, @bind ) = @{ ${ $resultset->as_query } };
    $dbh->do('SET enable_seqscan = off');
    my $lines = $dbh->selectcol_arrayref( "EXPLAIN (COSTS OFF) $sql",
        undef, map { ref $_ eq 'ARRAY' ? $_->[1] : $_ } @bind );
    $dbh->do('RESET enable_seqscan');

    return join "\n", @{$lines};
}

sub quietly {
    my ($code) = @_;

    my $output = q{};
    open my $handle, '>', \$output
      or croak 'failed to open output capture';
    my $status = do {
        local *STDOUT = $handle;
        $code->();
    };
    close $handle or croak 'failed to close output capture';

    return $status;
}

sub _open_barrier_pipes {
    pipe my $ready_reader, my $ready_writer or croak 'ready pipe failed';
    pipe my $go_reader,    my $go_writer    or croak 'go pipe failed';
    $ready_writer->autoflush(1);
    $go_writer->autoflush(1);

    return {
        go_reader    => $go_reader,
        go_writer    => $go_writer,
        ready_reader => $ready_reader,
        ready_writer => $ready_writer,
    };
}

sub _spawn_race_worker {
    my ( $worker, $slot, $pipes ) = @_;

    pipe my $out_reader, my $out_writer or croak 'result pipe failed';
    $out_writer->autoflush(1);
    my $pid = fork;
    if ( !defined $pid ) {
        croak "fork failed: $OS_ERROR";
    }
    if ( $pid == 0 ) {
        _child_wait_and_run(
            {
                out_reader => $out_reader,
                out_writer => $out_writer,
                pipes      => $pipes,
                slot       => $slot,
                worker     => $worker,
            }
        );
    }

    close $out_writer or croak 'parent out writer close failed';
    return { out => $out_reader, pid => $pid };
}

sub _child_wait_and_run {
    my ($job) = @_;

    _child_close_unused($job);
    _child_signal_ready( $job->{pipes} );
    _child_await_go( $job->{pipes} );
    _child_write_result( $job->{worker}, $job->{slot}, $job->{out_writer} );
    _exit(0);

    return;
}

sub _child_close_unused {
    my ($job) = @_;

    close $job->{pipes}{ready_reader}
      or croak 'child ready reader close failed';
    close $job->{pipes}{go_writer} or croak 'child go writer close failed';
    close $job->{out_reader}       or croak 'child out reader close failed';

    return;
}

sub _child_signal_ready {
    my ($pipes) = @_;

    print { $pipes->{ready_writer} } '1' or croak 'ready write failed';
    close $pipes->{ready_writer} or croak 'child ready writer close failed';

    return;
}

sub _child_await_go {
    my ($pipes) = @_;

    sysread $pipes->{go_reader}, my $go_byte, 1 or croak 'go read failed';
    close $pipes->{go_reader} or croak 'child go reader close failed';

    return;
}

sub _child_write_result {
    my ( $worker, $slot, $out_writer ) = @_;

    my $payload = _worker_payload( $worker, $slot );
    print {$out_writer} encode_json($payload) or croak 'result write failed';
    close $out_writer or croak 'child out writer close failed';

    return;
}

sub _worker_payload {
    my ( $worker, $slot ) = @_;

    my $result = eval { return $worker->($slot) };
    if ($EVAL_ERROR) {
        return { ok => 0, error => "$EVAL_ERROR" };
    }

    return { ok => 1, result => $result };
}

sub _release_workers {
    my ($pipes) = @_;

    _close_parent_barrier_ends($pipes);
    _drain_ready_signals( $pipes->{ready_reader} );
    _broadcast_go( $pipes->{go_writer} );

    return;
}

sub _close_parent_barrier_ends {
    my ($pipes) = @_;

    close $pipes->{ready_writer} or croak 'parent ready writer close failed';
    close $pipes->{go_reader}    or croak 'parent go reader close failed';

    return;
}

sub _drain_ready_signals {
    my ($ready_reader) = @_;

    for ( 1 .. $WORKER_COUNT ) {
        sysread $ready_reader, my $ready_byte, 1 or croak 'ready read failed';
    }
    close $ready_reader or croak 'parent ready reader close failed';

    return;
}

sub _broadcast_go {
    my ($go_writer) = @_;

    print {$go_writer} ( '1' x $WORKER_COUNT ) or croak 'go write failed';
    close $go_writer or croak 'parent go writer close failed';

    return;
}

sub _read_worker_outcome {
    my ($child) = @_;

    local $INPUT_RECORD_SEPARATOR = undef;
    my $json = readline $child->{out};
    close $child->{out} or croak 'parent out reader close failed';
    waitpid $child->{pid}, 0;

    return decode_json($json);
}

1;
