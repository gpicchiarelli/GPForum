package GPForum::Test::OutboxCommandDispatcher;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls => sub { return []; };

sub dispatch_pending {
    my ( $self, $limit ) = @_;

    push @{ $self->calls }, $limit;

    return {
        dead_lettered => 0,
        dispatched    => $limit,
        failed        => 0,
        selected      => $limit,
    };
}

1;
