# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::PostComposer;
use GPForum::Service::Forum::PostStore;
use GPForum::Service::Forum::ReadWorkflow;
use GPForum::Service::Forum::ThreadComposer;
use GPForum::Service::Forum::ThreadStore;
use GPForum::Test::Id;
use GPForum::Test::PostStoreLockDbh;
use GPForum::Test::PostStoreLockSchema;
use GPForum::Test::RefusingReadState;
use GPForum::Test::Schema;

our $VERSION = '0.001';

# The stores' unique-conflict recoveries that t/11 and t/12 reach only
# through another path giving the same answer: each case below fails if its
# recovery is taken out.

# A reply whose explicit position was taken meanwhile is stored at the next
# free one, under its own post id.
{
    my $schema = _lock_schema(
        posts => [ { post_id => 'post-1', position => 1, thread_id => 't-1' } ]
    );
    my $ids     = GPForum::Test::Id->new;
    my $command = _reply_command( $ids, position => 1 );
    my $created = _post_store( $schema, $ids )->create_post($command);

    ok( $created->{ok}, 'a taken explicit position is allocated again' );
    is( $created->{post}{position},
        2, 'the reply takes the next free position' );
    is(
        $created->{post}{post_id},
        $command->{post}{post_id},
        'a position conflict keeps the post id'
    );
}

# A post id taken by another thread's post is replaced in the post, its body
# and its revision.
{
    my $schema = _lock_schema( posts =>
          [ { post_id => 'generated-1', position => 1, thread_id => 'x' } ] );
    my $ids     = GPForum::Test::Id->new;
    my $created = _post_store( $schema, $ids )
      ->create_post( _reply_command( $ids, position => 1 ) );
    my $post_id = $created->{post}{post_id};

    isnt( $post_id, 'generated-1', 'a taken post id is replaced' );
    is( $schema->created_for('PostBody')->[0]{post_id},
        $post_id, 'the body belongs to the replaced post id' );
    is( $schema->created_for('PostRevision')->[0]{post_id},
        $post_id, 'the revision belongs to the replaced post id' );
}

# An edit whose explicit revision number was taken meanwhile is numbered
# after the post's highest.
{
    my $schema = _edit_schema(
        post_revisions => [ { post_id => 'post-1', revision_number => 1 } ] );
    my $edited =
      _post_store($schema)->edit_post( _edit_command( revision_number => 1 ) );

    ok( $edited->{ok}, 'a taken explicit revision number is allocated again' );
    is( $schema->created_for('PostRevision')->[0]{revision_number},
        2, 'the revision takes the next number' );
}

# An edit to the body the post already shows is skipped before anything is
# written, whatever ids its command carries.
{
    my $schema = _edit_schema(
        post_bodies => [
            { body_id => 'body-1', post_id => 'post-1', source_hash => 'same' }
        ]
    );
    my $edited =
      _post_store($schema)->edit_post( _edit_command( source_hash => 'same' ) );

    ok( $edited->{skipped}, 'an unchanged body skips the edit' );
    is( scalar @{ $schema->created_for('PostRevision') },
        0, 'an unchanged body writes no revision' );
    is( scalar @{ $schema->created_for('EventLog') },
        0, 'an unchanged body records nothing' );
}

# An earlier run of the same edit already pointed the post at its revision:
# skipped, recorded once.
{
    my $schema = _edit_schema(
        current_body_id     => undef,
        current_revision_id => 'revision-2',
        post_bodies         => [
            { body_id => 'body-2', post_id => 'post-1', source_hash => 'new' }
        ],
        post_revisions => [
            {
                body_id         => 'body-2',
                post_id         => 'post-1',
                revision_id     => 'revision-2',
                revision_number => 2,
            }
        ],
    );
    my $edited = _post_store($schema)->edit_post( _edit_command() );

    ok( $edited->{skipped}, 'an edit already pointed at is skipped' );
    is( scalar @{ $schema->created_for('EventLog') },
        0, 'an edit already pointed at records nothing again' );
}

# A thread id taken by another thread is replaced in the thread, its opening
# post and its counter, and the new thread is recorded under it.
{
    my $schema = GPForum::Test::Schema->new;
    $schema->resultset('Thread')->create(
        {
            author_user_id => 'user-other',
            category_id    => 'category-other',
            slug           => 'other',
            thread_id      => 'generated-1',
            title          => 'Other',
        }
    );
    my $ids = GPForum::Test::Id->new;
    my $created =
      _thread_store( $schema, $ids )->create_thread( _thread_command($ids) );
    my $thread_id = $created->{thread}{thread_id};

    isnt( $thread_id, 'generated-1', 'a taken thread id is replaced' );
    is( $schema->created_for('ThreadCounter')->[0]{thread_id},
        $thread_id, 'the counter belongs to the replaced thread id' );
    is( $created->{post}{thread_id},
        $thread_id, 'the opening post belongs to the replaced thread id' );
    is_deeply(
        [ map { $_->{event_type} } @{ $schema->created_for('EventLog') } ],
        [ 'thread.created', 'post.created' ],
        'the replaced thread is recorded once'
    );
    is( $schema->created_for('EventLog')->[0]{aggregate_id},
        $thread_id, 'thread.created names the replaced thread id' );
}

# A thread id taken in the same category under another slug is another
# thread, not an earlier run of this command.
{
    my $schema  = GPForum::Test::Schema->new;
    my $ids     = GPForum::Test::Id->new;
    my $command = _thread_command($ids);
    $schema->resultset('Thread')->create(
        {
            author_user_id => 'user-other',
            category_id    => $command->{thread}{category_id},
            slug           => 'another-slug',
            thread_id      => $command->{thread}{thread_id},
            title          => 'Another',
        }
    );
    my $created = _thread_store( $schema, $ids )->create_thread($command);

    ok( !$created->{skipped},
        'a same-category thread under another slug is not reused' );
    isnt(
        $created->{thread}{thread_id},
        $command->{thread}{thread_id},
        'its thread id is replaced'
    );
}

# A title edit that keeps the title but changes the slug is written.
{
    my $schema = _lock_schema(
        threads => [
            {
                author_user_id   => 'user-1',
                category_id      => 'category-1',
                moderation_state => 'visible',
                slug             => 'old-slug',
                thread_id        => 'thread-1',
                title            => 'Same title',
                version          => 1,
            }
        ]
    );
    my $edited = _thread_store($schema)->edit_thread(
        {
            idempotency_key => 'title-command',
            thread          => {
                editor_user_id => 'user-1',
                slug           => 'same-title',
                thread_id      => 'thread-1',
                title          => 'Same title',
            },
        }
    );

    ok( !$edited->{skipped}, 'a changed slug alone is not skipped' );
    is( $schema->threads->[0]{slug}, 'same-title', 'the new slug is stored' );
}

# ReadWorkflow passes a refusal of the read state on as it is.
{
    my $refusal = {
        errors => { last_read_position => 'last_read_position is invalid' },
        ok     => 0,
        status => 'invalid',
    };
    my $workflow = GPForum::Service::Forum::ReadWorkflow->new(
        read_state => GPForum::Test::RefusingReadState->new($refusal) );
    is_deeply(
        $workflow->mark_thread_read(
            { command_id => 'c-1', thread_id => 'thread-1', user_id => 'u-1' }
        ),
        $refusal,
        'a read-state refusal reaches the caller unchanged'
    );
}

done_testing();

sub _lock_schema (%rows) {
    return GPForum::Test::PostStoreLockSchema->new(
        lock_dbh => GPForum::Test::PostStoreLockDbh->new(
            thread_row => {
                author_user_id   => 'user-1',
                locked_at        => undef,
                moderation_state => 'visible',
            }
        ),
        %rows,
    );
}

# One live post by user-1 in thread-1, showing body-1 and revision-1.
sub _edit_schema (%override) {
    my %rows = map { $_ => delete $override{$_} }
      grep { exists $override{$_} } qw(post_bodies post_revisions);

    return _lock_schema(
        posts => [
            {
                author_user_id      => 'user-1',
                current_body_id     => 'body-1',
                current_revision_id => 'revision-1',
                post_id             => 'post-1',
                thread_id           => 'thread-1',
                version             => 1,
                %override,
            }
        ],
        %rows,
    );
}

sub _post_store ( $schema, $ids = GPForum::Test::Id->new ) {
    return GPForum::Service::Forum::PostStore->new(
        id_service => $ids,
        schema     => $schema,
    );
}

sub _thread_store ( $schema, $ids = GPForum::Test::Id->new ) {
    return GPForum::Service::Forum::ThreadStore->new(
        id_service => $ids,
        schema     => $schema,
    );
}

sub _reply_command ( $ids, %post ) {
    my $command =
      GPForum::Service::Forum::PostComposer->new( id_service => $ids )
      ->prepare(
        {
            allocate_position => 1,
            author_user_id    => 'user-1',
            body_hash         => 'hash-reply',
            body_source       => 'A reply',
            idempotency_key   => 'reply-command',
            thread_id         => 't-1',
            visibility        => 'public',
        }
      )->{command};
    $command->{post} = { %{ $command->{post} }, %post };

    return $command;
}

sub _edit_command (%field) {
    my $revision_number = delete $field{revision_number};

    return {
        body => {
            body_id     => 'body-2',
            body_source => 'Edited',
            post_id     => 'post-1',
            source_hash => 'new',
            %field,
        },
        idempotency_key => 'edit-command',
        post            => {
            editor_user_id => 'user-1',
            post_id        => 'post-1',
            thread_id      => 'thread-1',
        },
        revision => {
            body_id     => 'body-2',
            post_id     => 'post-1',
            revision_id => 'revision-2',
            defined $revision_number
            ? ( revision_number => $revision_number )
            : (),
        },
    };
}

sub _thread_command ($ids) {
    return GPForum::Service::Forum::ThreadComposer->new( id_service => $ids )
      ->prepare(
        {
            author_user_id  => 'user-1',
            body_hash       => 'hash-thread',
            body_source     => 'Opening body',
            category_id     => 'category-1',
            idempotency_key => 'thread-command',
            title           => 'A new thread',
            visibility      => 'public',
        }
      )->{command};
}

1;
