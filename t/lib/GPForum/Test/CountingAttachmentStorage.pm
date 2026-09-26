# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CountingAttachmentStorage;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has inner => undef;
has reads => sub { return []; };

sub read_object {
    my ( $self, $object_key ) = @_;

    push @{ $self->reads }, $object_key;

    return $self->inner->read_object($object_key);
}

sub write_object {
    my ( $self, $object_key, $content ) = @_;

    return $self->inner->write_object( $object_key, $content );
}

# Proxied so a delivery through this double takes the same streaming branch a
# real FilesystemStorage does. Without it the double would look like a backend
# that cannot name a path, and the read counter would prove nothing.
sub path_for {
    my ( $self, $object_key ) = @_;

    return $self->inner->path_for($object_key);
}

sub exists_object {
    my ( $self, $object_key ) = @_;

    return $self->inner->exists_object($object_key);
}

1;
