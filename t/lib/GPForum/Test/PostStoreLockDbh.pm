package GPForum::Test::PostStoreLockDbh;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls => sub { return []; };

sub selectrow_array {
    my ( $self, $sql, undef, @bind ) = @_;

    push @{ $self->calls }, { bind => \@bind, sql => $sql };

    return $bind[0];
}

1;
