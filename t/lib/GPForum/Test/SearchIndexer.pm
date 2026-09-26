# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SearchIndexer;

use strict;
use warnings;

use List::Util qw(max min);
use Mojo::Base -base;

our $VERSION = '0.001';

has calls => sub { return []; };

# A thread's post count, by thread id, and the batch index_thread_posts_batch
# takes: a thread with more posts than one batch reports where the next
# starts. A thread not listed has one post.
has thread_posts => sub { return {}; };
has batch_size   => 500;

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

sub index_thread_posts_batch {
    my ( $self, $thread_id, $after ) = @_;

    push @{ $self->calls }, [ thread_posts => $thread_id, $after ];

    # Positions 1 .. the thread's post count; a full batch names its last,
    # as the indexer does, even when no post follows it.
    my $start = ( $after // 0 ) + 1;
    my $end   = min(
        $start + $self->batch_size - 1,
        $self->thread_posts->{$thread_id} // 1
    );
    my $indexed = max( 0, $end - $start + 1 );

    return {
        indexed    => $indexed,
        next_after => $indexed == $self->batch_size ? $end : undef,
        pruned     => 0,
        thread_id  => $thread_id,
        unchanged  => 0,
    };
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

sub remove_thread {
    my ( $self, $thread_id ) = @_;

    push @{ $self->calls }, [ remove_thread => $thread_id ];

    return {
        ok          => 1,
        removed     => 1,
        entity_type => 'thread',
        entity_id   => $thread_id
    };
}

1;
