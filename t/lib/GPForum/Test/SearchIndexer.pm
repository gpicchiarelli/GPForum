package GPForum::Test::SearchIndexer;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has calls => sub { return []; };

sub index_thread {
    my ( $self, $thread_id ) = @_;

    push @{ $self->calls }, [ thread => $thread_id ];

    return { ok => 1, entity_type => 'thread', entity_id => $thread_id };
}

sub index_post {
    my ( $self, $post_id ) = @_;

    push @{ $self->calls }, [ post => $post_id ];

    return { ok => 1, entity_type => 'post', entity_id => $post_id };
}

sub remove_post {
    my ( $self, $post_id ) = @_;

    push @{ $self->calls }, [ remove_post => $post_id ];

    return {
        ok          => 1,
        removed     => 1,
        entity_type => 'post',
        entity_id   => $post_id
    };
}

1;
