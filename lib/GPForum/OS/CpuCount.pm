# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::CpuCount;

use strict;
use warnings;

use Const::Fast;
use English    qw(-no_match_vars);
use IPC::Open3 qw(open3);
use Mojo::Base -base, -signatures;
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

sub _first_count ( $self, $sources ) {
    for my $source ( @{$sources} ) {
        my $count = $self->_probe($source);
        if ($count) {
            return { count => $count, source => $source->{name} };
        }
    }

    return { count => $FALLBACK_COUNT, source => $FALLBACK_SOURCE };
}

sub _first_limit ( $self, $limits ) {
    for my $limit ( @{$limits} ) {
        my $quota = eval { return $self->_cgroup_quota($limit); };
        if ( _positive($quota) ) {
            return { count => _positive($quota), source => $limit->{name} };
        }
    }

    my $undefined;
    return $undefined;
}

sub _probe ( $self, $source ) {
    my $undefined;

    my $probe = $PROBE_FOR{ $source->{type} || q{} };
    if ( !$probe ) {
        return $undefined;
    }

    my $count = eval { return $probe->( $self, $source ); };
    if ( !$count ) {
        return $undefined;
    }

    return _positive($count);
}

sub _probe_command ( $self, $source ) {
    my $output = $self->command_runner->( @{ $source->{command} || [] } );
    if ( !defined $output ) {
        my $undefined;
        return $undefined;
    }

    my ($count) = $output =~ $INTEGER_VALUE;

    return $count;
}

sub _probe_cpu_list ( $self, $source ) {
    my $undefined;

    my $content = $self->file_reader->( $source->{path} );
    if ( !defined $content ) {
        return $undefined;
    }

    my $count = 0;
    for my $range ( split /,/msx, _trim($content) ) {
        my $size = _range_size($range);
        if ( !$size ) {
            return $undefined;
        }
        $count += $size;
    }

    return $count;
}

sub _probe_cpuinfo ( $self, $source ) {
    my $content = $self->file_reader->( $source->{path} );
    if ( !defined $content ) {
        my $undefined;
        return $undefined;
    }

    my @processors = grep { $_ =~ $CPUINFO_LINE } split /\n/msx, $content;

    return scalar @processors;
}

# The source is accepted and discarded: %PROBE_FOR dispatches every probe as
# $probe->( $self, $source ), and this one needs no source. Declaring only
# $self made the call die -- silently, because _probe wraps it in eval -- and
# the count fell back to 1.
sub _probe_sysconf ( $self, $ ) {
    return $self->sysconf_reader->();
}

sub _cgroup_quota ( $self, $limit ) {
    my $undefined;

    my $content = $self->file_reader->( $limit->{path} );
    if ( !defined $content ) {
        return $undefined;
    }

    my ( $quota, $period ) = $content =~ $CGROUP_QUOTA;
    if ( !$quota || !$period ) {
        return $undefined;
    }

    return ceil( $quota / $period );
}

sub _range_size ($range) {
    my $undefined;

    my ( $from, $to ) = $range =~ $CPU_RANGE;
    if ( !defined $from ) {
        return $undefined;
    }
    if ( !defined $to ) {
        return 1;
    }
    if ( $to < $from ) {
        return $undefined;
    }

    return $to - $from + 1;
}

sub _positive ($value) {
    my $undefined;

    if ( !defined $value || $value !~ $INTEGER_VALUE ) {
        return $undefined;
    }
    if ( $value < $FALLBACK_COUNT ) {
        return $undefined;
    }

    return int $value;
}

sub _trim ($value) {
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _run_command (@command) {
    my $undefined;

    if ( !@command || !-x $command[0] ) {
        return $undefined;
    }

    my $text = eval { return _capture_command(@command); };
    if ( !defined $text ) {
        return $undefined;
    }

    return $text;
}

sub _capture_command (@command) {
    my $undefined;

    delete local @ENV{@OPENMP_OVERRIDES};
    my $pid = open3( my $input, my $output, undef, @command );
    close $input or return $undefined;
    my $text = do { local $INPUT_RECORD_SEPARATOR = undef; <$output> };
    close $output or return $undefined;
    waitpid $pid, 0;

    return $CHILD_ERROR == 0 ? $text : undef;
}

sub _read_file ($path) {
    my $undefined;

    if ( !defined $path || !-r $path ) {
        return $undefined;
    }

    open my $handle, '<', $path or return $undefined;
    my $content = do { local $INPUT_RECORD_SEPARATOR = undef; <$handle> };
    close $handle or return $undefined;

    return $content;
}

sub _sysconf_processors {
    my $code = POSIX->can($NPROCESSORS_CONSTANT);
    if ( !$code ) {
        my $undefined;
        return $undefined;
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

Uses L<IPC::Open3>, L<POSIX>, and L<Mojo::Base>.

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
