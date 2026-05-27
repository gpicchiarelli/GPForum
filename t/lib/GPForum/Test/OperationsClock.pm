package GPForum::Test::OperationsClock;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has epoch => 100;

sub now_epoch {
    my ($self) = @_;

    return $self->epoch;
}

sub now_iso8601 {
    return '2026-05-23T12:00:00Z';
}

1;

