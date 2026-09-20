package GPForum::Test::CountingWrite;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has create_post_calls   => 0;
has create_thread_calls => 0;
has inner               => undef;

sub create_post {
    my ( $self, $command ) = @_;

    $self->create_post_calls( $self->create_post_calls + 1 );

    return $self->inner->create_post($command);
}

sub create_thread {
    my ( $self, $command ) = @_;

    $self->create_thread_calls( $self->create_thread_calls + 1 );

    return $self->inner->create_thread($command);
}

1;
