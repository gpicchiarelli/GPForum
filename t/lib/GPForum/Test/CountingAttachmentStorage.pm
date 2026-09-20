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

sub exists_object {
    my ( $self, $object_key ) = @_;

    return $self->inner->exists_object($object_key);
}

1;
