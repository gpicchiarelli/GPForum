package GPForum::Test::NotificationSearch;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has rows => sub { return []; };

sub all {
    my ($self) = @_;

    return @{ $self->rows };
}

sub count {
    my ($self) = @_;

    return scalar @{ $self->rows };
}

1;
