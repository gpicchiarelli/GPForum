package GPForum::Test::MigrationDbh;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has applied_versions => sub { return []; };
has executed         => sub { return []; };

sub selectall_arrayref {
    my ( $self, $query, $attributes ) = @_;

    return [ map { { version => $_ } } @{ $self->applied_versions } ];
}

sub execute_statement {
    my ( $self, $statement, $attributes, @bind ) = @_;

    push @{ $self->executed },
      {
        statement => $statement,
        bind      => \@bind,
      };

    return 1;
}

1;
