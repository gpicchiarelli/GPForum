# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS::Filesystem;

use strict;
use warnings;

use Carp    qw(croak);
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

has temporary_counter => 0;

sub write_atomic ( $self, $path, $content ) {
    _validate_write_input( $path, $content );

    my $temporary_path = $self->_temporary_path($path);
    _write_temporary_file( $temporary_path, $content );
    _promote_temporary_file( $temporary_path, $path );

    return {
        ok             => 1,
        path           => $path,
        temporary_path => $temporary_path,
    };
}

sub _validate_write_input ( $path, $content ) {
    if ( !defined $path || !length $path ) {
        croak 'path is required';
    }
    if ( !defined $content ) {
        croak 'content is required';
    }

    return;
}

sub _write_temporary_file ( $temporary_path, $content ) {
    open my $handle, '>', $temporary_path
      or croak "failed to open temporary file $temporary_path: $ERRNO";
    binmode $handle
      or _cleanup_and_croak( $temporary_path,
        "failed to set binary mode for $temporary_path: $ERRNO" );
    print {$handle} $content
      or _cleanup_and_croak( $temporary_path,
        "failed to write temporary file $temporary_path: $ERRNO" );
    close $handle
      or _cleanup_and_croak( $temporary_path,
        "failed to close temporary file $temporary_path: $ERRNO" );

    return;
}

sub _promote_temporary_file ( $temporary_path, $path ) {
    rename $temporary_path,
      $path
      or _cleanup_and_croak( $temporary_path,
        "failed to rename $temporary_path to $path: $ERRNO" );

    return;
}

sub _temporary_path ( $self, $path ) {
    my $counter = $self->temporary_counter + 1;
    $self->temporary_counter($counter);

    return join q{.}, $path, $PROCESS_ID, $counter, 'tmp';
}

sub _cleanup_and_croak ( $temporary_path, $message ) {
    if ( defined $temporary_path && -e $temporary_path ) {
        unlink $temporary_path;
    }
    croak $message;
}

1;
