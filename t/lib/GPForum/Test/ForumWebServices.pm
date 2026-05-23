package GPForum::Test::ForumWebServices;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub list_categories {
    return [
        {
            category_id => 'category-1',
            slug        => 'general',
            title       => 'General',
            description => 'General forum',
            visibility  => 'public',
            position    => 1,
        },
    ];
}

sub find_category {
    my ( $self, $category_id ) = @_;

    return if $category_id ne 'category-1';

    return $self->list_categories->[0];
}

sub list_category_threads {
    return {
        items => [
            {
                thread_id        => 'thread-1',
                category_id      => 'category-1',
                author_user_id   => 'user-1',
                title            => 'Welcome',
                slug             => 'welcome',
                pinned           => 0,
                visibility       => 'public',
                moderation_state => 'visible',
                locked_at        => undef,
                last_activity_at => '2026-05-23T12:00:00Z',
            },
        ],
        next_cursor => 'thread-cursor',
    };
}

sub find_thread {
    my ( $self, $thread_id ) = @_;

    return if $thread_id ne 'thread-1';

    return {
        thread_id        => 'thread-1',
        category_id      => 'category-1',
        author_user_id   => 'user-1',
        title            => 'Welcome',
        slug             => 'welcome',
        pinned           => 0,
        visibility       => 'public',
        moderation_state => 'visible',
        locked_at        => undef,
        last_activity_at => '2026-05-23T12:00:00Z',
    };
}

sub thread_page {
    my ( $self, $request ) = @_;

    my $thread = $self->find_thread( $request->{thread_id} );

    return { ok => 0, error => 'not_found' } if !$thread;

    return {
        ok     => 1,
        thread => $thread,
        posts  => {
            items => [
                {
                    post_id          => 'post-1',
                    thread_id        => 'thread-1',
                    author_user_id   => 'user-1',
                    position         => 1,
                    visibility       => 'public',
                    moderation_state => 'visible',
                    body             => 'First post',
                },
            ],
            next_cursor => 'post-cursor',
        },
    };
}

sub prepare {
    my ( $self, $input ) = @_;

    return { ok => 1, command => { post => { post_id => 'post-created' } } }
      if exists $input->{thread_id};

    return {
        ok      => 1,
        command => { thread => { thread_id => 'thread-created' } }
    };
}

sub create_thread {
    return { ok => 1, thread => { thread_id => 'thread-created' } };
}

sub create_post {
    return { ok => 1, post => { post_id => 'post-created' } };
}

sub next_position {
    return 2;
}

sub search {
    return [
        {
            entity_type => 'thread',
            entity_id   => 'thread-1',
            title       => 'Welcome',
            body        => 'First post',
            visibility  => 'public',
            indexed_at  => '2026-05-23T12:00:00Z',
        },
    ];
}

sub check {
    return { ok => 1 };
}

1;
