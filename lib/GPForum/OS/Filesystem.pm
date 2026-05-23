package GPForum::OS::Filesystem;

use strict;
use warnings;

use Carp    qw(croak);
use English qw(-no_match_vars);
use Mojo::Base -base;

our $VERSION = '0.001';

has temporary_counter => 0;

sub write_atomic {
    my ( $self, $path, $content ) = @_;

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

sub _validate_write_input {
    my ( $path, $content ) = @_;

    if ( !defined $path || !length $path ) {
        croak 'path is required';
    }
    if ( !defined $content ) {
        croak 'content is required';
    }

    return;
}

sub _write_temporary_file {
    my ( $temporary_path, $content ) = @_;

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

sub _promote_temporary_file {
    my ( $temporary_path, $path ) = @_;

    rename $temporary_path,
      $path
      or _cleanup_and_croak( $temporary_path,
        "failed to rename $temporary_path to $path: $ERRNO" );

    return;
}

sub _temporary_path {
    my ( $self, $path ) = @_;

    my $counter = $self->temporary_counter + 1;
    $self->temporary_counter($counter);

    return join q{.}, $path, $PROCESS_ID, $counter, 'tmp';
}

sub _cleanup_and_croak {
    my ( $temporary_path, $message ) = @_;

    if ( defined $temporary_path && -e $temporary_path ) {
        unlink $temporary_path;
    }
    croak $message;
}

1;
