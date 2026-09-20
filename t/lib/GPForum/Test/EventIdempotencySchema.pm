package GPForum::Test::EventIdempotencySchema;

use strict;
use warnings;

use Carp qw(croak);
use GPForum::Test::EventIdempotencyResultSet;
use Mojo::Base -base;

our $VERSION = '0.001';

has keys => sub { return GPForum::Test::EventIdempotencyResultSet->new; };

sub resultset {
    my ( $self, $name ) = @_;

    if ( $name ne 'EventIdempotencyKey' ) {
        croak 'unexpected resultset';
    }

    return $self->keys;
}

1;
