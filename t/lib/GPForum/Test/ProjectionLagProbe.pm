package GPForum::Test::ProjectionLagProbe;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has lag => sub {
    return {
        projection_name => 'search_documents',
        lag_seconds     => 2,
        status          => 'catching_up',
    };
};

sub observe_lag {
    my ($self) = @_;

    return $self->lag;
}

1;

