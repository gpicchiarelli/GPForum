package GPForum::Test::PurgeRow;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has deleted   => 0;
has on_delete => undef;
has values    => sub { return {}; };

sub get_column {
    my ( $self, $name ) = @_;

    return $self->values->{$name};
}

sub remove {
    my ($self) = @_;

    $self->deleted(1);
    if ( $self->on_delete ) {
        $self->on_delete->($self);
    }

    return 1;
}

1;
