# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::Memory;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::OS::CpuCount;

our $VERSION = '0.001';

# The memory GPForum sizes its caches from: the host's, or the cgroup's limit
# when a container is held to less. Each operating system names where it
# keeps the number; the first that answers wins, as for the CPUs.
const my $KIB           => 1_024;
const my $INTEGER_VALUE => qr{\A \s* ([[:digit:]]+) \s* \z}msx;
const my $MEMINFO_TOTAL => qr{^ MemTotal: \s+ ([[:digit:]]+) \s+ kB}msx;

# cgroup v1 writes "no limit" as a page-aligned number near 2**63; anything
# above this is no limit either.
const my $NO_LIMIT_ABOVE => 2**60;

const my %SOURCES => (
    darwin => [
        {
            name    => 'sysctl hw.memsize',
            command => [ '/usr/sbin/sysctl', '-n', 'hw.memsize' ],
        },
    ],
    freebsd => [
        {
            name    => 'sysctl hw.physmem',
            command => [ '/sbin/sysctl', '-n', 'hw.physmem' ],
        },
    ],
    linux => [ { name => '/proc/meminfo', meminfo => '/proc/meminfo' } ],
);
const my %LIMITS => (
    linux => [
        { name => 'cgroup v2 memory.max', path => '/sys/fs/cgroup/memory.max' },
        {
            name => 'cgroup v1 memory.limit_in_bytes',
            path => '/sys/fs/cgroup/memory/memory.limit_in_bytes',
        },
    ],
);

has command_runner => sub { return GPForum::OS::CpuCount->new->command_runner };
has file_reader    => sub { return GPForum::OS::CpuCount->new->file_reader };

# { bytes, source } for the operating system named (GPForum::OS's name):
# bytes is undef, and source 'unknown', when nothing answers.
sub detect ( $self, $os_name ) {
    my $name  = $os_name // q{};
    my $found = $self->_first( exists $SOURCES{$name} ? $SOURCES{$name} : [] );
    return { bytes => undef, source => 'unknown' } if !$found;

    my $limit = $self->_limit( exists $LIMITS{$name} ? $LIMITS{$name} : [] );
    return $found if !$limit || $limit->{bytes} >= $found->{bytes};

    return { %{$limit}, limited_from => $found->{bytes} };
}

sub _first ( $self, $sources ) {
    for my $source ( @{$sources} ) {
        my $bytes =
          exists $source->{command}
          ? _integer( $self->command_runner->( @{ $source->{command} } ) )
          : _meminfo( $self->file_reader->( $source->{meminfo} ) );
        return { bytes => $bytes, source => $source->{name} } if $bytes;
    }

    return undef;
}

sub _limit ( $self, $limits ) {
    for my $limit ( @{$limits} ) {
        my $bytes = _integer( $self->file_reader->( $limit->{path} ) );
        return { bytes => $bytes, source => $limit->{name} }
          if $bytes && $bytes < $NO_LIMIT_ABOVE;
    }

    return undef;
}

sub _integer ($text) {
    my ($number) = ( $text // q{} ) =~ $INTEGER_VALUE;

    return $number ? $number + 0 : undef;
}

sub _meminfo ($text) {
    my ($kib) = ( $text // q{} ) =~ $MEMINFO_TOTAL;

    return $kib ? $kib * $KIB : undef;
}

1;

__END__

=head1 NAME

GPForum::OS::Memory - The memory this host gives GPForum.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $memory = GPForum::OS::Memory->new->detect( GPForum::OS->detect->name );
    my $bytes  = $memory->{bytes};    # undef when nothing answered

=head1 DESCRIPTION

Reads the host's physical memory where its operating system keeps it --
C<sysctl -n hw.memsize> on macOS, C<sysctl -n hw.physmem> on FreeBSD,
C<MemTotal> in C</proc/meminfo> on Linux -- and, on Linux, lowers it to a
cgroup's memory limit (v2 C<memory.max>, then v1
C<memory.limit_in_bytes>), so a container held to 512 MB is not sized as the
whole host. L<GPForum::Config> sizes the per-process cache from it.

=head1 SUBROUTINES/METHODS

=head2 detect

Takes the operating system's name, as L<GPForum::OS> names it (C<darwin>,
C<freebsd>, C<linux>), and returns C<{ bytes, source }>, plus
C<limited_from> (the host's bytes) when a cgroup limit lowered it. C<bytes>
is undef and C<source> is C<unknown> when no source answers.

=head1 DIAGNOSTICS

None: a source that does not answer is skipped, and detection never throws.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, and L<GPForum::OS::CpuCount>
for its command runner and file reader.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The physical memory, not what is free: a host that runs PostgreSQL beside
GPForum shares it, which the cache's share of it allows for.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
