package GPForum::Test::OutboxRow;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has data    => sub { return {}; };
has updates => sub { return []; };

sub update {
    my ( $self, $changes ) = @_;

    push @{ $self->updates }, $changes;
    for my $key ( keys %{$changes} ) {
        $self->data->{$key} = $changes->{$key};
    }

    return $self;
}

sub get_column {
    my ( $self, $column ) = @_;

    return $self->data->{$column};
}

1;
