package GPForum::Test::EngineeringCorrectness::Row;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has data => sub { return {}; };

sub get_column {
    my ( $self, $column ) = @_;

    return $self->data->{$column};
}

sub update {
    my ( $self, $changes ) = @_;

    my $data = $self->data;
    for my $column ( keys %{$changes} ) {
        $data->{$column} = $changes->{$column};
    }

    return $self;
}

1;
