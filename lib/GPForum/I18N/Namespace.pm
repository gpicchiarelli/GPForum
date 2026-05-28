package GPForum::I18N::Namespace;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub namespace_for {
    my ( $self, $key ) = @_;

    return if !$self->valid_key($key);

    my ($namespace) = split /[.]/msx, $key, 2;
    return $namespace;
}

sub valid_key {
    my ( $self, $key ) = @_;

    return 0 if !defined $key || $key !~ /\A [a-z][a-z0-9_]* [.] /msx;
    return 0 if $key                  !~ /\A [a-z0-9_.-]+ \z/msx;
    return 1;
}

1;
