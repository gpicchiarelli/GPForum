# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Infrastructure::Antivirus::Command;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use File::Spec;
use File::Temp qw(tempfile);
use IPC::Open3 qw(open3);
use Mojo::Base -base, -signatures;
use Symbol qw(gensym);

our $VERSION = '0.001';

const my $DEFAULT_TIMEOUT => 120;
const my $EXIT_CLEAN      => 0;
const my $EXIT_INFECTED   => 1;
const my $STATUS_SHIFT    => 8;
const my $SIGNAL_MASK     => 127;
const my $NO_STATUS       => -1;
const my $PRIVATE_FILE    => oct '600';

# A scanner the operating system installed, run once per file, that follows
# ClamAV's exit convention: 0 nothing found, 1 something found, anything else
# an error. clamdscan and clamscan do. The file's path is appended to the
# command, which runs without a shell. For a server that will not keep a
# resident clamd -- clamscan loads its signatures on every run, which is slow
# but needs no daemon.
has command         => sub { return []; };
has timeout_seconds => $DEFAULT_TIMEOUT;

# Never used inside a request -- answers_immediately is false -- and its health
# runs no process, so there is nothing to bound further.
sub within_request ($self) {
    return $self;
}

# A process per file -- clamscan loads its whole signature database each run
# -- so uploads are left to the attachment worker rather than scanned inside
# the request.
sub answers_immediately {
    return 0;
}

# For readiness: the program must exist and be executable. Whether it works is
# what bin/gpforum antivirus_check proves, with a test file.
# For readiness: the program must resolve to an executable file, through PATH
# when it is a bare name, as exec itself would find it. Whether it detects
# anything is what bin/gpforum-antivirus-check proves, with a test file.
sub health ( $self, $ ) {
    my ($program) = @{ $self->command };
    my %check = ( mode => 'command', program => $program );
    if ( !defined _resolved($program) ) {
        return {
            %check,
            status => 'degraded',
            error  => 'antivirus command is not an executable file'
        };
    }

    return { %check, status => 'ok' };
}

# Whether a batch of scans is worth starting: the program can be found.
sub available ($self) {
    my ($program) = @{ $self->command };

    return defined _resolved($program) ? 1 : 0;
}

sub scan ( $self, $content ) {
    my $outcome = eval { return $self->_run($content); };
    if ( !$outcome ) {
        return { status => 'error', error => _trimmed($EVAL_ERROR) };
    }

    return _verdict( $self->_engine, $outcome );
}

sub _engine ($self) {
    my ($program) = @{ $self->command };
    return 'command' if !defined $program;

    ( my $name = $program ) =~ s{\A .* /}{}msx;

    return $name;
}

sub _resolved ($program) {
    return if !defined $program || !length $program;
    if ( $program =~ m{/}msx ) {
        return -f $program && -x _ ? $program : undef;
    }
    for my $directory ( File::Spec->path ) {
        my $candidate = File::Spec->catfile( $directory, $program );
        return $candidate if -f $candidate && -x _;
    }

    return;
}

# One cleanup path for the private copy, whatever fails: writing it, running
# the scanner or reading the result. UNLINK => 0, because File::Temp records
# every UNLINK file for removal at exit, and a worker runs for weeks.
sub _run ( $self, $content ) {
    my @command = @{ $self->command };
    croak 'no antivirus command configured' if !@command;
    if ( !utf8::downgrade( $content, 1 ) ) {
        croak 'antivirus content must be bytes, not characters';
    }

    my ( $handle, $path ) =
      tempfile( 'gpforum-scan-XXXXXXXX', TMPDIR => 1, UNLINK => 0 );
    my $result = eval {
        _write_private( $handle, $path, $content );
        return $self->_execute( [ @command, $path ] );
    };
    my $error = $EVAL_ERROR;
    unlink $path;
    croak $error if !$result;

    return { %{$result}, path => $path };
}

# Private to this user. A scanner that reads the file itself must run as this
# user or be handed the descriptor (clamdscan --fdpass).
sub _write_private ( $handle, $path, $content ) {
    chmod $PRIVATE_FILE, $path or croak "chmod $path: $ERRNO";
    binmode $handle          or croak "binmode $path: $ERRNO";
    print {$handle} $content or croak "write $path: $ERRNO";
    close $handle            or croak "close $path: $ERRNO";

    return;
}

# The timeout covers the whole run -- output and exit both -- so a scanner
# that closes its output and carries on is still stopped.
sub _execute ( $self, $command ) {
    my $output = gensym;
    my $pid    = open3( my $input, $output, undef, @{$command} );
    close $input or croak "close scanner input: $ERRNO";

    my $finished = eval {
        local $SIG{ALRM} = sub { die "antivirus command timed out\n" };
        alarm $self->timeout_seconds;
        local $INPUT_RECORD_SEPARATOR = undef;
        my $read = <$output>;
        waitpid $pid, 0;
        my $status = $CHILD_ERROR;
        alarm 0;
        return { status => $status, output => defined $read ? $read : q{} };
    };
    alarm 0;
    if ( !$finished ) {
        my $error = $EVAL_ERROR;
        kill 'KILL', $pid;
        waitpid $pid, 0;
        croak $error;
    }

    return $finished;
}

# Clean only for a scanner that ran to the end and said so. A process killed
# by a signal -- the OOM killer, or a crash on a crafted file -- has a wait
# status whose exit byte is 0, and that is not a verdict.
sub _verdict ( $engine, $outcome ) {
    my $status = $outcome->{status};
    if ( $status == $NO_STATUS ) {
        return { status => 'error', error => "$engine could not be run" };
    }
    if ( my $signal = $status & $SIGNAL_MASK ) {
        return {
            status => 'error',
            error  => "$engine killed by signal $signal"
        };
    }

    my $exit = $status >> $STATUS_SHIFT;
    if ( $exit == $EXIT_CLEAN ) {
        return { status => 'clean', engine => $engine };
    }
    if ( $exit == $EXIT_INFECTED ) {
        return {
            status    => 'infected',
            engine    => $engine,
            signature => _signature( $outcome->{output}, $outcome->{path} ),
        };
    }

    return { status => 'error', error => "$engine exited $exit" };
}

# The "PATH: NAME FOUND" line for the file scanned, one line at a time:
# scanners print warnings (an old signature database) on the same stream.
sub _signature ( $output, $path ) {
    for my $line ( split /\n/msx, $output ) {
        return $1 if $line =~ /\A \Q$path\E : \s+ (.+?) \s+ FOUND \s* \z/msx;
    }
    for my $line ( split /\n/msx, $output ) {
        return $1 if $line =~ /: \s+ ([^:]+?) \s+ FOUND \s* \z/msx;
    }

    return 'unnamed';
}

sub _trimmed ($message) {
    my $text = defined $message ? "$message" : 'unknown scanner failure';
    $text =~ s/\s+ at \s+ \S+ \s+ line \s+ \d+ [.]? \s* \z//msx;
    chomp $text;

    return $text;
}

1;

__END__

=head1 NAME

GPForum::Infrastructure::Antivirus::Command - Scan bytes with a system scanner.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $scanner = GPForum::Infrastructure::Antivirus::Command->new(
        command => [ '/usr/bin/clamdscan', '--fdpass', '--no-summary' ] );
    my $verdict = $scanner->scan($bytes);

=head1 DESCRIPTION

Runs an antivirus program installed by the operating system once per file,
without a shell, on a private temporary copy of the bytes, and reads its exit
status with ClamAV's convention: 0 clean, 1 infected, anything else an error.

=head1 SUBROUTINES/METHODS

=head2 within_request

The scanner itself: a command is not run inside a request.

=head2 answers_immediately

False: a process per file is too slow for the upload request, so the
attachment worker scans.

=head2 available

True when the program resolves to an executable file.

=head2 health

For readiness: C<ok> when the program is an executable file, C<degraded>
otherwise.

=head2 scan

Returns a hash with C<status> C<clean>, C<infected> (with C<signature>, taken
from a C<path: NAME FOUND> line when the scanner prints one) or C<error>.

=head1 DIAGNOSTICS

C<scan> never dies. A missing program, a timeout or an unexpected exit status
is an C<error> verdict, never a clean one.

=head1 CONFIGURATION AND ENVIRONMENT

C<GPFORUM_ANTIVIRUS_COMMAND> holds the command, split on whitespace; the file
path is appended. C<GPFORUM_ANTIVIRUS_TIMEOUT_SECONDS> bounds each run.

=head1 DEPENDENCIES

L<IPC::Open3>, L<File::Temp>, L<Const::Fast>, L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A scanner that does not follow the 0/1/2 exit convention cannot be used as is.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
