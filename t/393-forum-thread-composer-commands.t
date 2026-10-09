# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::ThreadComposer;
use GPForum::Test::Id;

our $VERSION = '0.001';

# Every row a new thread's command carries, field by field, and the commands
# and refusals of a title edit and a move. t/11 checks the fields it reads;
# this pins the rest, as ThreadComposer gave them before its helpers were
# folded together: the state a thread and its first post start in, the
# counter, the slug's edges and fallback, the title's length bounds and
# folding, the shortest body, and what a refused new thread hands back.

const my $LONGEST_TITLE => 160;

plan tests => 9;

my $composer = GPForum::Service::Forum::ThreadComposer->new(
    id_service => GPForum::Test::Id->new );

my %new_state = (
    deleted_at         => undef,
    deleted_by         => undef,
    locked_at          => undef,
    moderation_state   => 'visible',
    permission_version => 1,
    version            => 1,
    visibility         => 'members',
    visibility_version => 1,
);

is_deeply(
    $composer->prepare(
        {
            author_user_id   => 'u1',
            body_hash        => 'h1',
            body_source      => ' *hi* ',
            category_id      => ' c1 ',
            idempotency_key  => 'k1',
            title            => "  --Hello,\n\tWorld!--  ",
            visibility_floor => 'members',
        }
    ),
    {
        command => {
            body => {
                body_format        => 'markdown',
                body_id            => 'generated-3',
                body_rendered_safe => '<p><em>hi</em></p>',
                body_source        => '*hi*',
                post_id            => 'generated-2',
                source_hash        => 'h1',
            },
            counter => {
                last_post_id        => undef,
                reconciled_at       => undef,
                reply_count         => 0,
                thread_id           => 'generated-1',
                version             => 1,
                visible_reply_count => 0,
            },
            idempotency_key => 'k1',
            post            => {
                %new_state,
                author_user_id      => 'u1',
                current_body_id     => 'generated-3',
                current_revision_id => 'generated-4',
                hidden_at           => undef,
                position            => 1,
                post_id             => 'generated-2',
                thread_id           => 'generated-1',
            },
            revision => {
                body_id         => 'generated-3',
                edit_reason     => undef,
                editor_user_id  => 'u1',
                post_id         => 'generated-2',
                revision_id     => 'generated-4',
                revision_number => 1,
            },
            thread => {
                %new_state,
                author_user_id => 'u1',
                category_id    => 'c1',
                pinned         => 0,
                slug           => 'hello-world',
                thread_id      => 'generated-1',
                title          => '--Hello, World!--',
            },
        },
        ok => 1,
    },
    'a new thread writes every row in its starting state, inheriting the floor'
);

is_deeply(
    $composer->prepare( {} ),
    {
        errors => {
            author_user_id => 'author_user_id is required',
            body_hash      => 'body_hash is required',
            body_source    => 'body is required',
            category_id    => 'category_id is required',
            title          => 'title is required',
        },
        ok     => 0,
        values => {
            author_user_id   => q{},
            body_hash        => q{},
            body_source      => q{},
            category_id      => q{},
            idempotency_key  => q{},
            title            => q{},
            visibility       => 'public',
            visibility_floor => 'public',
        },
    },
    'a refused new thread names each missing field and hands back its values'
);

ok(
    $composer->prepare(
        {
            author_user_id => 'u1',
            body_hash      => 'h1',
            body_source    => 'x',
            category_id    => 'c1',
            title          => 'Hello',
        }
    )->{ok},
    'a body of one character is accepted'
);

is(
    $composer->prepare_title(
        {
            editor_user_id => 'u2',
            thread_id      => 't1',
            title          => " New\n\ttitle  here ",
        }
    )->{command}{thread}{title},
    'New title here',
    'a title edit is trimmed and folded onto one line'
);

is_deeply(
    $composer->prepare_title(
        {
            editor_user_id  => 'u2',
            idempotency_key => 'k2',
            thread_id       => 't1',
            title           => '!!!',
        }
    ),
    {
        command => {
            idempotency_key => 'k2',
            thread          => {
                editor_user_id => 'u2',
                slug           => 'thread',
                thread_id      => 't1',
                title          => '!!!',
            },
        },
        ok => 1,
    },
    'a title with no letter or digit gets the slug "thread"'
);

ok(
    $composer->prepare_title(
        {
            editor_user_id => 'u2',
            thread_id      => 't1',
            title          => 'x' x $LONGEST_TITLE,
        }
    )->{ok},
    'a title of the longest length is accepted'
);

is_deeply(
    $composer->prepare_title( { title => 'x' x ( $LONGEST_TITLE + 1 ) } )
      ->{errors},
    {
        editor_user_id => 'editor_user_id is required',
        thread_id      => 'thread_id is required',
        title          => 'title length is invalid',
    },
    'a title edit names each missing field and a title one too long'
);

is_deeply(
    $composer->prepare_move( {} ),
    {
        errors => {
            category_id    => 'category_id is required',
            editor_user_id => 'editor_user_id is required',
            thread_id      => 'thread_id is required',
        },
        ok     => 0,
        values => {
            category_id     => q{},
            editor_user_id  => q{},
            idempotency_key => q{},
            thread_id       => q{},
        },
    },
    'a move names each missing field'
);

is_deeply(
    $composer->prepare_move(
        {
            category_id     => 'c2',
            editor_user_id  => 'u2',
            idempotency_key => 'k3',
            thread_id       => 't1',
        }
    ),
    {
        command => {
            idempotency_key => 'k3',
            thread          => {
                category_id    => 'c2',
                editor_user_id => 'u2',
                thread_id      => 't1',
            },
        },
        ok => 1,
    },
    'a move carries the category, editor and thread'
);

1;
