package GPForum::Test::ModerationSchema;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

has resultsets => sub { return {}; };
has storage    => undef;

sub resultset {
    my ( $self, $name ) = @_;

    return $self->resultsets->{$name} if exists $self->resultsets->{$name};

    croak 'unexpected resultset';
}

sub txn_do {
    my ( $self, $callback ) = @_;

    return $callback->();
}

1;
