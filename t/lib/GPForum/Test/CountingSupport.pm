package GPForum::Test::CountingSupport;

use strict;
use warnings;

use Mojo::Base 'GPForum::Service::Identity::Support';

our $VERSION = '0.001';

has updates => 0;

sub update_row {
    my ( $self, $row, $values ) = @_;

    $self->updates( $self->updates + 1 );

    return $self->SUPER::update_row( $row, $values );
}

1;
