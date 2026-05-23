package GPForum::Test::OutboxDispatcher;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls => sub { return []; };

sub dispatch_pending {
    my ( $self, $limit ) = @_;

    push @{ $self->calls }, $limit;

    return {
        selected      => 1,
        dispatched    => 1,
        failed        => 0,
        dead_lettered => 0,
    };
}

1;
