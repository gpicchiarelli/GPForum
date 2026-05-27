package GPForum::Test::AttachmentSchema;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has resultsets   => sub { return {}; };
has transactions => 0;

sub resultset {
    my ( $self, $name ) = @_;

    return $self->resultsets->{$name};
}

sub txn_do {
    my ( $self, $code ) = @_;

    $self->transactions( $self->transactions + 1 );

    return $code->();
}

1;

