package GPForum::Service::Attachment::FilesystemStorage;

use strict;
use warnings;

use Carp           qw(croak);
use English        qw(-no_match_vars);
use File::Basename qw(dirname);
use File::Path     qw(make_path);
use File::Spec;
use Mojo::Base -base;

use GPForum::OS::Filesystem;

our $VERSION = '0.001';

has filesystem => sub { return GPForum::OS::Filesystem->new; };
has root       => 'var/attachments';

sub write_object {
    my ( $self, $object_key, $content ) = @_;

    _validate_content($content);

    my $path      = $self->path_for($object_key);
    my $directory = dirname($path);
    make_path($directory) if defined $directory && length $directory;

    my $written = $self->filesystem->write_atomic( $path, $content );

    return {
        %{$written},
        byte_size  => length $content,
        object_key => $object_key,
    };
}

sub read_object {
    my ( $self, $object_key ) = @_;

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

sub delete_object {
    my ( $self, $object_key ) = @_;

    my $path = $self->path_for($object_key);
    return { ok => 1, object_key => $object_key, deleted => 0 } if !-e $path;

    unlink $path
      or croak "failed to delete attachment object $object_key: $ERRNO";

    return { ok => 1, object_key => $object_key, deleted => 1 };
}

sub exists_object {
    my ( $self, $object_key ) = @_;

    return -e $self->path_for($object_key) ? 1 : 0;
}

sub path_for {
    my ( $self, $object_key ) = @_;

    _validate_object_key($object_key);

    return File::Spec->catfile( $self->root, split m{/}msx, $object_key );
}

sub _validate_content {
    my ($content) = @_;

    croak 'attachment content is required' if !defined $content;

    return;
}

sub _validate_object_key {
    my ($object_key) = @_;

    croak 'attachment object key is required'
      if !defined $object_key || !length $object_key;
    croak 'attachment object key must be relative'
      if File::Spec->file_name_is_absolute($object_key);
    croak 'attachment object key is unsafe'
      if $object_key =~ m{(?: \A | / ) [.] [.] (?: / | \z )}msx;
    croak 'attachment object key is unsafe'
      if $object_key =~ m{[^A-Za-z0-9._/\-]}msx;

    return;
}

1;
