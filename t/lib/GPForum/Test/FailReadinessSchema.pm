package GPForum::Test::FailReadinessSchema;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

sub storage {
    my ($self) = @_;

    return $self;
}

sub dbh {
    croak 'database unavailable';
}

sub resultset {
    my ( $self, $name ) = @_;

    return $self;
}

sub search {
    return;
}

1;
