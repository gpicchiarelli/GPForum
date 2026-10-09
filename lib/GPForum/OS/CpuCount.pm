# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::CpuCount;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;
use v5.40;
use POSIX qw(ceil sysconf);

our $VERSION = '0.001';

const my $FALLBACK_COUNT       => 1;
const my $FALLBACK_SOURCE      => 'fallback';
const my $NPROCESSORS_CONSTANT => '_SC_NPROCESSORS_ONLN';
const my $CPU_RANGE     => qr{\A ([[:digit:]]+) (?:-([[:digit:]]+))? \z}msx;
const my $CPUINFO_LINE  => qr{\A processor \s* : }msx;
const my $CGROUP_QUOTA  => qr{\A ([[:digit:]]+) \s+ ([[:digit:]]+) \s* \z}msx;
const my $INTEGER_VALUE => qr{\A \s* ([[:digit:]]+) \s* \z}msx;
const my @OPENMP_OVERRIDES => qw(OMP_NUM_THREADS OMP_THREAD_LIMIT);
const my %PROBE_FOR => (
    command  => \&_probe_command,
    cpu_list => \&_probe_cpu_list,
    cpuinfo  => \&_probe_cpuinfo,
    sysconf  => \&_probe_sysconf,
);

has command_runner => sub { return \&_run_command; };
has file_reader    => sub { return \&_read_file; };
has sysconf_reader => sub { return \&_sysconf_processors; };

sub detect ( $self, $sources, $limits ) {
    my $found = $self->_first_count( $sources || [] );
    my $limit = $self->_first_limit( $limits  || [] );
    if ( $limit && $limit->{count} < $found->{count} ) {
        return {
            %{$found},
            count      => $limit->{count},
            limited_by => $limit->{source},
        };
    }

    return $found;
}

# The first source that answers a positive count. A source of a type
# %PROBE_FOR does not name is skipped -- the table is read-only, and reading
# it with an unknown key dies -- and so is a probe that dies.
sub _first_count ( $self, $sources ) {
    for my $source ( @{$sources} ) {
        my $type = $source->{type} // q{};
        if ( !exists $PROBE_FOR{$type} ) {
            next;
        }

        my $count;
        try {
            my $answer = $PROBE_FOR{$type}->( $self, $source );
            $count = _positive($answer);
        }
        catch ($error) {
            $count = undef;
        };
        if ($count) {
            return { count => $count, source => $source->{name} };
        }
    }

    return { count => $FALLBACK_COUNT, source => $FALLBACK_SOURCE };
}

# The first cgroup CPU quota -- "QUOTA PERIOD", rounded up to whole CPUs --
# that reads as positive; "max" and a file that cannot be read are no limit.
sub _first_limit ( $self, $limits ) {
    for my $limit ( @{$limits} ) {
        my $quota;
        try {
            my $content = $self->file_reader->( $limit->{path} ) // q{};
            my ( $cpu_time, $period ) = $content =~ $CGROUP_QUOTA;
            $quota = $cpu_time && $period ? ceil( $cpu_time / $period ) : undef;
        }
        catch ($error) {
            $quota = undef;
        };
        if ( _positive($quota) ) {
            return { count => _positive($quota), source => $limit->{name} };
        }
    }

    return undef;
}

sub _probe_command ( $self, $source ) {
    my $output = $self->command_runner->( @{ $source->{command} || [] } );
    if ( !defined $output ) {
        return undef;
    }

    my ($count) = $output =~ $INTEGER_VALUE;

    return $count;
}

# A CPU list such as "0-3,6,8-9"; a range that is malformed or runs
# backwards makes the whole list unreadable.
sub _probe_cpu_list ( $self, $source ) {
    my $content = $self->file_reader->( $source->{path} );
    if ( !defined $content ) {
        return undef;
    }

    my $count = 0;
    for my $range ( split /,/msx, trim($content) ) {
        my ( $from, $to ) = $range =~ $CPU_RANGE;
        if ( !defined $from || ( defined $to && $to < $from ) ) {
            return undef;
        }
        $count += defined $to ? $to - $from + 1 : 1;
    }

    return $count;
}

sub _probe_cpuinfo ( $self, $source ) {
    my $content = $self->file_reader->( $source->{path} );
    if ( !defined $content ) {
        return undef;
    }

    my @processors = grep { $_ =~ $CPUINFO_LINE } split /\n/msx, $content;

    return scalar @processors;
}

# The source is accepted and discarded: %PROBE_FOR dispatches every probe as
# $probe->( $self, $source ), and this one needs no source. Declaring only
# $self made the call die -- silently, because _first_count catches it -- and
# the count fell back to 1.
sub _probe_sysconf ( $self, $ ) {
    return $self->sysconf_reader->();
}

sub _positive ($value) {
    if ( !defined $value || $value !~ $INTEGER_VALUE ) {
        return undef;
    }
    if ( $value < $FALLBACK_COUNT ) {
        return undef;
    }

    return int $value;
}

# The command's output when it exits 0. OpenMP's thread overrides are dropped
# for the run: nproc honours them, and they say nothing about the host.
#
# A list-form pipe open hands the child the pipe as its descriptor 1 and
# leaves the parent's handles alone. IPC::Open3, which this used, works on
# STDOUT and STDERR by name: called while they were in-memory handles -- a
# test capturing a command's output -- it printed the count to the real
# terminal and closed the caller's capture under it.
sub _run_command (@command) {
    if ( !@command || !-x $command[0] ) {
        return undef;
    }

    my $text;
    try {
        delete local @ENV{@OPENMP_OVERRIDES};
        if ( open my $output, q{-|}, @command ) {
            my $read = do { local $INPUT_RECORD_SEPARATOR = undef; <$output> };
            $text = close $output ? $read : undef;
        }
    }
    catch ($error) {
        $text = undef;
    };

    return $text;
}

sub _read_file ($path) {
    if ( !defined $path || !-r $path ) {
        return undef;
    }

    open my $handle, '<', $path or return undef;
    my $content = do { local $INPUT_RECORD_SEPARATOR = undef; <$handle> };
    close $handle or return undef;

    return $content;
}

# An optional capability: a POSIX that does not name _SC_NPROCESSORS_ONLN
# has no count to give, so the name is asked about rather than assumed.
sub _sysconf_processors {
    my $code = POSIX->can($NPROCESSORS_CONSTANT);
    if ( !$code ) {
        return undef;
    }

    return sysconf( $code->() );
}

1;

__END__

=head1 NAME

GPForum::OS::CpuCount - Host CPU count detection with injectable probes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $detection = GPForum::OS::CpuCount->new->detect(
        [
            {
                name    => 'sysctl hw.logicalcpu',
                type    => 'command',
                command => [ '/usr/sbin/sysctl', '-n', 'hw.logicalcpu' ],
            },
        ],
        [ { name => 'cgroup cpu.max', path => '/sys/fs/cgroup/cpu.max' } ],
    );
    my $cpus = $detection->{count};

=head1 DESCRIPTION

Detects the number of CPUs available to the current process. Each
C<GPForum::OS::*> profile supplies an ordered list of sources; the first
source returning a positive integer wins. Optional limits (Linux cgroup v2
C<cpu.max> quotas) can lower the result, so a container restricted to one
CPU is not sized as the whole host. When no source answers, the count falls
back to 1 and C<source> is C<fallback>.

Source types:

=over 4

=item C<command>

Runs C<command> (argument list, no shell) and expects a single integer, for
example C<sysctl -n hw.logicalcpu> or C<nproc>. Missing executables are
skipped.

=item C<cpu_list>

Reads a kernel CPU list file such as C</sys/devices/system/cpu/online>
(C<0-3,6>).

=item C<cpuinfo>

Counts C<processor> lines in C</proc/cpuinfo>.

=item C<sysconf>

Uses C<POSIX::sysconf(_SC_NPROCESSORS_ONLN)> when the running perl exposes
the constant (most builds do not).

=back

=head1 SUBROUTINES/METHODS

=head2 detect

Takes an array reference of sources and an optional array reference of
limits. Returns C<{ count, source }>, plus C<limited_by> when a quota
lowered the count.

=head1 DIAGNOSTICS

Probe failures are swallowed and the next source is tried; detection never
throws.

=head1 CONFIGURATION AND ENVIRONMENT

C<command_runner>, C<file_reader>, and C<sysconf_reader> are injectable code
references so tests do not depend on the host. C<OMP_NUM_THREADS> and
C<OMP_THREAD_LIMIT> are removed from the environment of probe commands
because GNU C<nproc> honors them.

=head1 DEPENDENCIES

Uses L<POSIX> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

cgroup v1 CFS quotas and FreeBSD C<cpuset> restrictions are not read; use
C<GPFORUM_RUNTIME_WORKER_POLICY=configured> with an explicit
C<GPFORUM_WEB_PROCESSES> on such hosts.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
