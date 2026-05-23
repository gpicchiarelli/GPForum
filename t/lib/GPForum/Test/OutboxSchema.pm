package GPForum::Test::OutboxSchema;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

has outbox_resultset => undef;

sub resultset {
    my ( $self, $name ) = @_;

    croak 'unexpected resultset' if $name ne 'OutboxMessage';

    return $self->outbox_resultset;
}

1;
