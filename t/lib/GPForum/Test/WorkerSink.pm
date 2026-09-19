package GPForum::Test::WorkerSink;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has records => sub { return []; };

sub capture {
    my ( $self, $row ) = @_;

    push @{ $self->records }, $row;

    return $row;
}

1;
