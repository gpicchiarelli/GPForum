package GPForum::Test::IdempotencyStore;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has done   => sub { return {}; };
has events => sub { return []; };

sub is_done {
    my ( $self, $key ) = @_;

    return $self->done->{$key} ? 1 : 0;
}

sub begin {
    my ( $self, $key ) = @_;

    push @{ $self->events }, [ begin => $key ];

    return;
}

sub mark_done {
    my ( $self, $key, $result ) = @_;

    $self->done->{$key} = 1;
    push @{ $self->events }, [ done => $key, $result ];

    return;
}

sub mark_failed {
    my ( $self, $key, $error ) = @_;

    push @{ $self->events }, [ failed => $key, $error ];

    return;
}

1;
