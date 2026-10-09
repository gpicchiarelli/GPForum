# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Attachment::FilesystemStorage;

use Carp           qw(croak);
use English        qw(-no_match_vars);
use File::Basename qw(dirname);
use File::Path     qw(make_path);
use File::Spec;
use GPForum::X::Argument;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::OS::Filesystem;

our $VERSION = '0.001';

has filesystem => sub { return GPForum::OS::Filesystem->new; };
has root       => 'var/attachments';

sub write_object ( $self, $object_key, $content ) {
    _validate_content($content);

    my $path      = $self->path_for($object_key);
    my $directory = dirname($path);
    if ( defined $directory && length $directory ) {
        make_path($directory);
    }

    my $written = $self->filesystem->write_atomic( $path, $content );

    return {
        %{$written},
        byte_size  => length $content,
        object_key => $object_key,
    };
}

sub read_object ( $self, $object_key ) {
    my $path = $self->path_for($object_key);
    open my $handle, '<', $path
      or croak "failed to open attachment object $object_key: $ERRNO";
    binmode $handle
      or croak
      "failed to set binary mode for attachment object $object_key: $ERRNO";
    local $INPUT_RECORD_SEPARATOR = undef;
    my $content = <$handle>;
    close $handle
      or croak "failed to close attachment object $object_key: $ERRNO";

    return $content;
}

sub delete_object ( $self, $object_key ) {
    my $path = $self->path_for($object_key);
    return { ok => 1, object_key => $object_key, deleted => 0 } if !-e $path;

    unlink $path
      or croak "failed to delete attachment object $object_key: $ERRNO";

    return { ok => 1, object_key => $object_key, deleted => 1 };
}

sub exists_object ( $self, $object_key ) {
    return -e $self->path_for($object_key) ? 1 : 0;
}

sub path_for ( $self, $object_key ) {
    _validate_object_key($object_key);

    return File::Spec->catfile( $self->root, split m{/}msx, $object_key );
}

sub _validate_content ($content) {
    if ( !defined $content ) {
        GPForum::X::Argument->throw(
            message => 'attachment content is required' );
    }

    return;
}

sub _validate_object_key ($object_key) {
    if ( !defined $object_key || !length $object_key ) {
        GPForum::X::Argument->throw(
            message => 'attachment object key is required' );
    }
    if ( File::Spec->file_name_is_absolute($object_key) ) {
        GPForum::X::Argument->throw(
            message => 'attachment object key must be relative' );
    }
    if ( $object_key =~ m{(?: \A | / ) [.] [.] (?: / | \z )}msx ) {
        GPForum::X::Argument->throw(
            message => 'attachment object key is unsafe' );
    }
    if ( $object_key =~ m{[^[:alnum:]._/-]}msxa ) {
        GPForum::X::Argument->throw(
            message => 'attachment object key is unsafe' );
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Attachment::FilesystemStorage - Attachment objects as files under one root directory.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $storage = GPForum::Service::Attachment::FilesystemStorage->new(
        root => 'var/attachments',
    );

    $storage->write_object( $object_key, $bytes );
    my $path = $storage->path_for($object_key);
    $storage->delete_object($object_key);

=head1 DESCRIPTION

The attachment storage backend that keeps each object as a file under
C<root> (default C<var/attachments>). An object key is a relative path; it
is split on C</> and joined under the root. A key that is empty, absolute,
contains a C<..> segment, or contains anything but letters, digits, C<.>,
C<_>, C</> and C<-> is refused, so a key cannot reach outside the root.
Writes go through L<GPForum::OS::Filesystem/write_atomic>. Because the
backend can name a path, L<GPForum::Service::Attachment::Delivery> streams
downloads from it instead of reading them into memory.

=head1 SUBROUTINES/METHODS

=head2 write_object

Takes an object key and the content. Creates the parent directories, writes
the file atomically, and returns the C<write_atomic> result (C<ok>, C<path>,
C<temporary_path>) with C<byte_size> and C<object_key> added.

=head2 read_object

Takes an object key. Returns the file's content, read in binary mode.

=head2 delete_object

Takes an object key. Removes the file and returns
C<< { ok => 1, object_key => $key, deleted => 1 } >>, or C<< deleted => 0 >>
when there was no file.

=head2 exists_object

Takes an object key. Returns 1 when the file exists and 0 otherwise.

=head2 path_for

Takes an object key. Returns the file path under C<root>, after checking
the key.

=head1 DIAGNOSTICS

Croaks C<attachment object key is required>,
C<attachment object key must be relative> or
C<attachment object key is unsafe> for a bad key;
C<attachment content is required> when C<write_object> gets undef content;
C<failed to open attachment object KEY: ERROR>, and the matching binary mode
and close messages, from C<read_object>; and
C<failed to delete attachment object KEY: ERROR> from C<delete_object>.
Errors from C<make_path> and C<write_atomic> propagate.

=head1 CONFIGURATION AND ENVIRONMENT

The C<root> attribute, which the bootstrap sets from the configuration's
C<attachment_root>. A relative root resolves against the working directory.

=head1 DEPENDENCIES

L<GPForum::OS::Filesystem>.

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
