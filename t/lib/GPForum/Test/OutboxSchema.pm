package GPForum::Test::OutboxSchema;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

has outbox_resultset      => undef;
has dead_letter_resultset => undef;
has storage               => undef;

sub txn_do {
    my ( $self, $code ) = @_;

    return $code->();
}

sub resultset {
    my ( $self, $name ) = @_;

    return $self->outbox_resultset      if $name eq 'OutboxMessage';
    return $self->dead_letter_resultset if $name eq 'DeadLetter';

    croak 'unexpected resultset';
}

1;
