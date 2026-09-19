package GPForum::Test::SharedCacheClient;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

has store => sub { return {}; };
has mode  => sub { return 'ok'; };

sub get {
    my ( $self, $key ) = @_;

    $self->_fail_if_down;
    if ( !exists $self->store->{$key} ) {
        croak 'not found';
    }

    return $self->store->{$key};
}

sub put {
    my ( $self, $key, $value ) = @_;

    if ( $self->mode ne 'ok' ) {
        return { outcome => 'rejected' };
    }

    $self->store->{$key} = $value;
    return { outcome => 'committed' };
}

sub erase {
    my ( $self, $key ) = @_;

    if ( $self->mode ne 'ok' ) {
        return { outcome => 'rejected' };
    }

    delete $self->store->{$key};
    return { outcome => 'committed' };
}

sub ping {
    my ($self) = @_;

    $self->_fail_if_down;
    return q{};
}

sub _fail_if_down {
    my ($self) = @_;

    if ( $self->mode ne 'ok' ) {
        croak 'unavailable: connection refused';
    }

    return;
}

1;
