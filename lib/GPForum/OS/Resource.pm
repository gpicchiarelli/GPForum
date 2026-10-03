# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::Resource;

use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;
use v5.40;
use POSIX qw(sysconf);

our $VERSION = '0.001';

use constant OPEN_MAX_CONSTANT => '_SC_OPEN_MAX';

sub snapshot ($self) {
    return {
        open_file_descriptors => $self->open_file_descriptors,
        file_descriptor_limit => $self->file_descriptor_limit,
        swap_pressure         => $self->swap_pressure,
    };
}

sub open_file_descriptors ($self) {
    for my $path ( _fd_paths() ) {
        my $count = _count_directory_entries($path);
        return $count if defined $count;
    }

    return undef;
}

sub file_descriptor_limit ($self) {
    my $code = POSIX->can(OPEN_MAX_CONSTANT);
    return undef if !$code;

    my $limit = eval { return sysconf( $code->() ); };
    return undef if !$limit || $limit < 1;

    return $limit;
}

sub swap_pressure ($self) {
    my $linux = _linux_swap_pressure();
    return $linux if $linux;

    return {
        status => 'unknown',
        reason => 'portable swap pressure probe unavailable',
    };
}

sub _linux_swap_pressure {
    my $path = '/proc/meminfo';
    return undef if !-r $path;

    open my $handle, '<', $path or return undef;
    my %values;
    while ( my $line = <$handle> ) {
        if ( $line =~ /\A (SwapTotal|SwapFree): \s+ ([0-9]+) /msx ) {
            $values{$1} = int $2;
        }
    }
    close $handle or return undef;

    return undef if !$values{SwapTotal};

    my $used_ratio =
      ( $values{SwapTotal} - ( $values{SwapFree} || 0 ) ) / $values{SwapTotal};

    return {
        status     => _swap_status($used_ratio),
        used_ratio => sprintf '%.3f',
        $used_ratio,
    };
}

sub _swap_status ($used_ratio) {
    return 'high'    if $used_ratio >= 0.8;
    return 'warning' if $used_ratio >= 0.5;

    return 'ok';
}

sub _fd_paths {
    return ( "/proc/$PROCESS_ID/fd", '/dev/fd' );
}

sub _count_directory_entries ($path) {
    opendir my $directory, $path or return undef;
    my @entries = grep { _is_real_entry($_) } readdir $directory;
    closedir $directory or return undef;

    return scalar @entries;
}

sub _is_real_entry ($entry) {
    return $entry ne q{.} && $entry ne q{..};
}

1;
