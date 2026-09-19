package GPForum::Test::SearchSearch;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

BEGIN {
    *delete = \&_delete_rows;
}

has resultset => undef;
has rows      => sub { return []; };

sub as_rows {
    my ($self) = @_;

    return @{ $self->rows };
}

sub all {
    my ($self) = @_;

    return @{ $self->rows };
}

sub _delete_rows {
    my ($self) = @_;

    push @{ $self->resultset->deleted }, $self->resultset->last_query;

    return 1;
}

1;
