package GPForum::Service::Search::DocumentBuilder;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_LANGUAGE         => 'simple';
const my $DEFAULT_PERMISSION_SCOPE => 'public';
const my $EMPTY_TEXT               => q{};

sub build_thread {
    my ( $self, $thread ) = @_;

    return if !_thread_is_visible($thread);

    return {
        entity_type        => 'thread',
        entity_id          => $thread->get_column('thread_id'),
        category_id        => $thread->get_column('category_id'),
        author_user_id     => $thread->get_column('author_user_id'),
        space_id           => _space_id_for_thread($thread),
        visibility         => $thread->get_column('visibility'),
        permission_scope   => _permission_scope($thread),
        visibility_version => $thread->get_column('visibility_version'),
        permission_version => $thread->get_column('permission_version'),
        language           => $DEFAULT_LANGUAGE,
        title              => $thread->get_column('title'),
        body               => $thread->get_column('title'),
        source_version     => $thread->get_column('version'),
        source_created_at  => $thread->get_column('created_at'),
    };
}

sub build_post {
    my ( $self, $post ) = @_;

    return if !_post_is_visible($post);

    my $thread = $post->thread;
    return if !_thread_is_visible($thread);

    my $body = $post->current_body;

    return {
        entity_type        => 'post',
        entity_id          => $post->get_column('post_id'),
        category_id        => $thread->get_column('category_id'),
        author_user_id     => $post->get_column('author_user_id'),
        space_id           => _space_id_for_thread($thread),
        visibility         => $post->get_column('visibility'),
        permission_scope   => _permission_scope($post),
        visibility_version => $post->get_column('visibility_version'),
        permission_version => $post->get_column('permission_version'),
        language           => $DEFAULT_LANGUAGE,
        title              => $thread->get_column('title'),
        body               => _body_text($body),
        source_version     => $post->get_column('version'),
        source_created_at  => $post->get_column('created_at'),
    };
}

sub _thread_is_visible {
    my ($row) = @_;

    return if !$row;
    return if defined $row->get_column('deleted_at');

    my $state = $row->get_column('moderation_state');
    return $state && ( $state eq 'visible' || $state eq 'locked' ) ? 1 : 0;
}

sub _post_is_visible {
    my ($row) = @_;

    return if !$row;
    return if defined $row->get_column('deleted_at');

    return $row->get_column('moderation_state') eq 'visible' ? 1 : 0;
}

sub _permission_scope {
    my ($row) = @_;

    return $row->get_column('visibility') || $DEFAULT_PERMISSION_SCOPE;
}

sub _space_id_for_thread {
    my ($thread) = @_;

    return $thread->get_column('space_id')
      if $thread->can('has_column')
      && $thread->has_column('space_id');

    return if !$thread->can('category');

    my $category = $thread->category;
    return if !$category;

    return $category->get_column('space_id');
}

sub _body_text {
    my ($body) = @_;

    return $EMPTY_TEXT if !$body;
    return
         $body->get_column('body_rendered_safe')
      || $body->get_column('body_source')
      || $EMPTY_TEXT;
}

1;
