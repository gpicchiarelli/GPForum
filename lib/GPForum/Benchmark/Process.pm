# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Benchmark::Process;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English  qw(-no_match_vars);
use Exporter qw(import);
use IO::Socket::INET;
use IPC::Open3  qw(open3);
use POSIX       qw(setsid WNOHANG _exit);
use Symbol      qw(gensym);
use Time::HiRes qw(sleep time);

use GPForum::X::Unavailable;

our $VERSION = '0.001';

our @EXPORT_OK = qw(
  command_output
  find_binary
  free_port
  git_commit
  read_pid_file
  spawn
  terminate
  wait_for_exit
  wait_until_ready
  worker_pids
);

const my $DEFAULT_STARTUP_TIMEOUT => 15;
const my $HTTP_OK                 => 200;
const my $READY_SLEEP             => 0.1;
const my $STOP_SLEEP              => 0.1;
const my $STOP_ATTEMPTS           => 50;
const my $KILL_ATTEMPTS           => 20;
const my $EXEC_FAILED             => 127;

# Runs a command in a child, its output appended to the log and, for a
# server, in a session of its own so a signal to the group reaches all its
# processes. Returns the child's pid, undef when there is no child. A child
# that cannot exec writes why to the log and exits 127 there: dying unwound
# into the copy of the parent's code it carries, and inside benchmark_report's
# try a reverse proxy that failed to exec went on to stop the hypnotoad its
# parent was measuring.
sub spawn ( $child, @command ) {
    my $pid = fork;
    return $pid if !defined $pid || $pid;

    try {
        if ( $child->{session} ) {
            setsid or croak "failed to create $child->{name} process session";
        }
        open STDOUT, '>>', $child->{log_file}
          or croak "failed to open $child->{log_file}";
        open STDERR, '>>', $child->{log_file}
          or croak "failed to open $child->{log_file}";
        local %ENV = ( %ENV, %{ $child->{environment} || {} } );
        exec @command or croak "failed to exec $child->{name}";
    }
    catch ($error) {
        print {*STDERR} "$error\n" or _exit($EXEC_FAILED);
    };

    return _exit($EXEC_FAILED);
}

# Ends a process group the polite way first: TERM, then KILL when it outlives
# the wait, and the pid file it may leave behind.
sub terminate ($runtime) {
    my $pid = $runtime->{process_pid};
    if ($pid) {
        kill 'TERM', -$pid;
    }
    wait_for_exit($pid) and return;

    if ($pid) {
        kill 'KILL', -$pid;
    }
    for ( 1 .. $KILL_ATTEMPTS ) {
        return if waitpid( $pid, WNOHANG ) == $pid;
        sleep $STOP_SLEEP;
    }

    if ( $runtime->{pid_file} && -e $runtime->{pid_file} ) {
        unlink $runtime->{pid_file};
    }

    return;
}

sub wait_for_exit ($pid) {
    return 1 if !$pid;
    for ( 1 .. $STOP_ATTEMPTS ) {
        return 1 if waitpid( $pid, WNOHANG ) == $pid;
        sleep $STOP_SLEEP;
    }

    return 0;
}

# Asks the runtime's /health/live until it answers 200, for the startup
# timeout its environment sets or 15 seconds.
sub wait_until_ready ( $runtime, $name ) {
    $name ||= 'hypnotoad';

    my $timeout = $DEFAULT_STARTUP_TIMEOUT;
    if ( $runtime->{environment}
        && exists $runtime->{environment}{GPFORUM_STARTUP_TIMEOUT} )
    {
        $timeout = $runtime->{environment}{GPFORUM_STARTUP_TIMEOUT};
    }

    my $deadline = time + $timeout;
    while ( time < $deadline ) {
        try {
            my $tx =
              $runtime->{ua}->get( $runtime->{base_url} . '/health/live' );
            return 1 if ( $tx->result->code || 0 ) == $HTTP_OK;
        }
        catch ($error) {

            # Not listening yet: it is still starting, so ask again.
        };
        sleep $READY_SLEEP;
    }

    GPForum::X::Unavailable->throw( message => $name
          . ' did not become ready; see '
          . $runtime->{log_file} );
}

sub find_binary ($name) {
    for my $directory ( split /:/msx, $ENV{PATH} || q{} ) {
        next if !length $directory;
        my $candidate = "$directory/$name";
        return $candidate if -x $candidate && !-d $candidate;
    }

    return undef;
}

# What a command prints on both streams, its whitespace folded to single
# spaces; 'unknown' when it prints nothing or cannot start.
sub command_output (@command) {
    my $stdout;
    my $stderr = gensym;
    my $pid;
    try {
        $pid = open3( undef, $stdout, $stderr, @command );
    }
    catch ($error) {

        # No such binary, or it would not start: there is no version to read.
        return 'unknown';
    };

    # Both handles close as the sub returns.
    my $output = do {
        local $INPUT_RECORD_SEPARATOR = undef;
        ( <$stdout> // q{} ) . ( <$stderr> // q{} );
    };
    waitpid $pid, 0;

    $output =~ s/\A \s+//msx;
    $output =~ s/\s+ \z//msx;
    $output =~ s/\s+/ /gmsx;

    return length $output ? $output : 'unknown';
}

sub free_port {
    my $socket = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
    ) or croak 'failed to allocate a local benchmark port';

    my $port = $socket->sockport;
    close $socket or croak 'failed to close benchmark port probe socket';

    return $port;
}

sub read_pid_file ($pid_file) {
    return undef if !$pid_file || !-e $pid_file;

    open my $handle, '<', $pid_file or return undef;
    my $pid = <$handle>;
    close $handle or return undef;

    return undef if !defined $pid;
    $pid =~ s/\A \s+//msx;
    $pid =~ s/\s+ \z//msx;

    return $pid =~ /\A [[:digit:]]+ \z/msx ? int $pid : undef;
}

# The hypnotoad or GPForum children of a master process, from ps. Request
# unlimited width so a terminal or COLUMNS cannot hide the command marker.
sub worker_pids ($master_pid) {
    return [] if !$master_pid;

    open my $processes, q{-|}, 'ps', '-axww', '-o', 'pid=,ppid=,command='
      or return [];
    my @lines = <$processes>;
    close $processes or return [ _children_of( $master_pid, @lines ) ];

    return [ _children_of( $master_pid, @lines ) ];
}

sub _children_of ( $master_pid, @lines ) {
    my @workers;
    for my $line (@lines) {
        my ( $pid, $parent, $command ) =
          $line =~ /\A \s* ([[:digit:]]+) \s+ ([[:digit:]]+) \s+ (.+) \z/msx
          or next;
        next if $parent != $master_pid;
        next if $command !~ /hypnotoad|gpforum/msx;
        push @workers, int $pid;
    }

    return @workers;
}

sub git_commit {
    open my $git, q{-|}, qw(git rev-parse --short HEAD)
      or return 'unknown';
    my $commit = <$git>;
    close $git or return 'unknown';
    return 'unknown' if !defined $commit;

    chomp $commit;
    return length $commit ? $commit : 'unknown';
}

1;

__END__

=head1 NAME

GPForum::Benchmark::Process - The processes the server benchmarks run.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use GPForum::Benchmark::Process qw(spawn terminate);

    my $pid = spawn( { name => 'nginx', log_file => $log, session => 1 },
        $binary, '-c', $config );
    terminate( { process_pid => $pid, pid_file => $pid_file } );

=head1 DESCRIPTION

How L<GPForum::Command::HypnotoadBenchmark> starts, watches and stops the
hypnotoad and reverse proxy it measures, and what it reads about them: a
free port, a pid file, a master's workers, the commit being measured. Every
function is exported on request only.

=head1 SUBROUTINES/METHODS

=head2 spawn

Given C<< { name, log_file, environment, session } >> and a command, forks a
child that appends its output to the log, runs in a session of its own when
C<session> is true, and execs the command with the environment added. Returns
the child's pid, undef when it could not fork. A child that cannot exec says
why in the log and exits 127.

=head2 terminate

Given C<< { process_pid, pid_file } >>, sends TERM to the process group,
then KILL when it outlives the wait, and removes a pid file left behind.

=head2 wait_for_exit

Given a pid, waits up to five seconds for it to exit: 1 when it did (or there
is no pid), 0 otherwise.

=head2 wait_until_ready

Given a runtime (C<ua>, C<base_url>, C<log_file>, C<environment>) and a name,
returns once C</health/live> answers 200; throws L<GPForum::X::Unavailable>
naming the log when it does not within C<GPFORUM_STARTUP_TIMEOUT> (15
seconds by default).

=head2 find_binary

The executable of that name on C<PATH>, or undef.

=head2 command_output

What a command prints on standard output and standard error, whitespace
folded, or C<unknown>.

=head2 free_port

A TCP port on 127.0.0.1 that was free when asked.

=head2 read_pid_file

The pid a pid file holds, or undef.

=head2 worker_pids

Given a master pid, an array reference of its hypnotoad or GPForum
children, as C<ps> lists them.

=head2 git_commit

The short commit of the working tree, or C<unknown>.

=head1 DIAGNOSTICS

C<failed to allocate a local benchmark port>; C<NAME did not become ready;
see LOG>; in a child, C<failed to exec NAME> in the log.

=head1 CONFIGURATION AND ENVIRONMENT

C<PATH>, for L</find_binary>.

=head1 DEPENDENCIES

L<Const::Fast>, L<English>, L<Exporter>, L<IO::Socket::INET>, L<IPC::Open3>, L<POSIX>,
L<Symbol>, L<Time::HiRes>.

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
