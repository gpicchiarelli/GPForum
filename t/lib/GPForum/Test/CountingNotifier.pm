package GPForum::Test::CountingNotifier;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls => sub { return []; };

sub notify {
    my ( $self, $event ) = @_;

    push @{ $self->calls }, $event;

    return { ok => 1 };
}

1;
