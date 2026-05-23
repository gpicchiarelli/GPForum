package GPForum::OS::Resource;

use strict;
use warnings;

use English qw(-no_match_vars);
use Mojo::Base -base;

our $VERSION = '0.001';

sub snapshot {
    my ($self) = @_;

    return { open_file_descriptors => $self->open_file_descriptors, };
}

sub open_file_descriptors {
    my ($self) = @_;

    for my $path ( _fd_paths() ) {
        my $count = _count_directory_entries($path);
        return $count if defined $count;
    }

    return;
}

sub _fd_paths {
    return ( "/proc/$PROCESS_ID/fd", '/dev/fd' );
}

sub _count_directory_entries {
    my ($path) = @_;

    opendir my $directory, $path or return;
    my @entries = grep { _is_real_entry($_) } readdir $directory;
    closedir $directory or return;

    return scalar @entries;
}

sub _is_real_entry {
    my ($entry) = @_;

    return $entry ne q{.} && $entry ne q{..};
}

1;
