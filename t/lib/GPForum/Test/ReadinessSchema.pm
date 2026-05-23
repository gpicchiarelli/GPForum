package GPForum::Test::ReadinessSchema;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub storage {
    my ($self) = @_;

    return $self;
}

sub dbh {
    my ($self) = @_;

    return $self;
}

sub selectrow_array {
    return 1;
}

sub resultset {
    my ($self) = @_;

    return $self;
}

sub search {
    return;
}

1;
