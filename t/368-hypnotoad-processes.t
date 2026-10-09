# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use POSIX      qw(WNOHANG);
use Test::More;
use Time::HiRes qw(sleep);

use lib 'lib';

use GPForum::Command::HypnotoadBenchmark;

our $VERSION = '0.001';

# How the hypnotoad benchmark starts and stops the processes it measures: a
# child that runs its command with its output in the log, a child that
# cannot exec ending there rather than running on through the parent's code,
# and a process group that is stopped with TERM.

const my $EXEC_FAILED       => 127;
const my $EXIT_STATUS_SHIFT => 8;
const my $SETTLE_SECONDS    => 0.05;
const my $SETTLE_ATTEMPTS   => 100;
const my $NO_CHILD          => -1;

my $directory = tempdir( CLEANUP => 1 );

_test_spawned_command();
_test_failed_exec();
_test_terminate();

done_testing();

sub _test_spawned_command {
    my $log = "$directory/ok.log";
    my $pid = _private('_spawn')->(
        { name => 'echo', log_file => $log, environment => { GPF_T => 'x' } },
        $EXECUTABLE_NAME,
        '-e',
        '$| = 1; print "said $ENV{GPF_T}\n"; warn "warned\n"',
    );
    waitpid $pid, 0;

    is( $CHILD_ERROR, 0, 'a spawned command runs to its own end' );
    is(
        path($log)->slurp,
        "said x\nwarned\n",
        'its output and errors go to the log, with the environment given'
    );

    return;
}

sub _test_failed_exec {
    my $log    = "$directory/failed.log";
    my $marker = "$directory/unwound";
    my $pid;
    try {
        $pid = _private('_spawn')->(
            { name => 'nothing', log_file => $log, session => 1 },
            "$directory/no-such-program", '--flag',
        );
    }
    catch ($error) {

        # Only a child that unwound into this code could get here.
        path($marker)->spew('unwound');
    };
    waitpid $pid, 0;

    is( $CHILD_ERROR >> $EXIT_STATUS_SHIFT,
        $EXEC_FAILED, 'a child that cannot exec exits 127' );
    like(
        path($log)->slurp,
        qr/^failed[ ]to[ ]exec[ ]nothing[ ]/msx,
        'and says why in the log'
    );
    ok( !-e $marker, 'without running on through the code that spawned it' );

    return;
}

sub _test_terminate {
    my $pid = _private('_spawn')->(
        {
            name     => 'sleeper',
            log_file => "$directory/sleeper.log",
            session  => 1,
        },
        $EXECUTABLE_NAME,
        '-e',
        'sleep 60',
    );
    _wait_for_session($pid);

    _private('_terminate')->( { process_pid => $pid } );

    is( waitpid( $pid, WNOHANG ),
        $NO_CHILD, 'a terminated group has been reaped' );

    return;
}

# The child calls setsid before it execs; signalling its group before then
# would reach this test instead.
sub _wait_for_session ($pid) {
    for ( 1 .. $SETTLE_ATTEMPTS ) {
        return if getpgrp($pid) == $pid;
        sleep $SETTLE_SECONDS;
    }
    croak "child $pid never led its own session";
}

sub _private ($name) {
    return GPForum::Command::HypnotoadBenchmark->can($name) // croak "no $name";
}

1;
