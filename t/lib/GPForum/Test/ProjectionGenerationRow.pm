package GPForum::Test::ProjectionGenerationRow;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has data      => sub { return {}; };
has resultset => undef;
has updates   => sub { return []; };

sub update {
    my ( $self, $changes ) = @_;

    $self->_guard_active_unique($changes);
    push @{ $self->updates }, $changes;
    for my $key ( keys %{$changes} ) {
        $self->data->{$key} = $changes->{$key};
    }

    return $self;
}

sub _guard_active_unique {
    my ( $self, $changes ) = @_;

    my $resultset = $self->resultset;
    if ( !$resultset ) {
        return;
    }

    $resultset->assert_active_unique( $self, $changes );

    return;
}

sub get_column {
    my ( $self, $column ) = @_;

    return $self->data->{$column};
}

1;
