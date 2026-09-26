# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Forum;
use GPForum::Config;
use GPForum::Service::Clock;
use GPForum::Service::Forum::PostingWorkflow;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::PostReader;
use Mojolicious;

our $VERSION = '0.001';

can_ok( 'GPForum::Bootstrap::Forum', 'register' );
can_ok( 'GPForum::Service::Forum::PostingWorkflow',
    qw(create_reply create_thread delete_post delete_thread edit_post edit_thread move_thread restore_post restore_thread)
);

my $application = Mojolicious->new();
$application->secrets( ['bootstrap-forum-test'] );
$application->helper(
    gp_schema => sub { return GPForum::Test::Schema->new(); } );
$application->helper( gp_id => sub { return GPForum::Test::Id->new(); } );
$application->helper(
    gp_clock => sub { return GPForum::Service::Clock->new(); } );
$application->helper(
    gp_local_cache => sub { return GPForum::Test::Cache->new(); } );
$application->helper(
    gp_mention_store => sub { return GPForum::Test::MentionStore->new(); } );
$application->helper(
    gp_command_idempotency => sub {
        my $undefined;
        return $undefined;
    }
);
$application->helper(
    gp_realtime_hub => sub { return GPForum::Test::RealtimeHub->new(); } );

GPForum::Bootstrap::Forum->register(
    application => $application,
    config      => GPForum::Config->new(),
);

my $controller = $application->build_controller;
isa_ok( $controller->gp_category_reader,
    'GPForum::Service::Forum::CategoryReader' );
isa_ok( $controller->gp_thread_reader,
    'GPForum::Service::Forum::ThreadReader' );
isa_ok(
    $controller->gp_home_page_reader,
    'GPForum::Service::Forum::HomePageReader'
);
isa_ok( $controller->gp_post_reader, 'GPForum::Service::Forum::PostReader' );
isa_ok(
    $controller->gp_thread_detail_reader,
    'GPForum::Service::Forum::ThreadDetailReader'
);
isa_ok( $controller->gp_thread_composer,
    'GPForum::Service::Forum::ThreadComposer' );
isa_ok( $controller->gp_thread_store, 'GPForum::Service::Forum::ThreadStore' );
isa_ok( $controller->gp_post_composer,
    'GPForum::Service::Forum::PostComposer' );
isa_ok( $controller->gp_post_store, 'GPForum::Service::Forum::PostStore' );
isa_ok( $controller->gp_post_position,
    'GPForum::Service::Forum::PostPosition' );
isa_ok( $controller->gp_thread_read_state,
    'GPForum::Service::Forum::ReadState' );
isa_ok(
    $controller->gp_thread_read_workflow,
    'GPForum::Service::Forum::ReadWorkflow'
);
isa_ok( $controller->gp_posting_workflow,
    'GPForum::Service::Forum::PostingWorkflow' );

my $missing_thread_command        = _workflow();
my $missing_thread_command_result = $missing_thread_command->create_thread(
    {
        category_id    => 'general',
        author_user_id => 'user-1',
        body_source    => 'body',
        title          => 'Hello',
        visibility     => 'public',
    }
);
is( $missing_thread_command_result->{status},
    'invalid', 'thread write requires command id' );
is_deeply(
    $missing_thread_command_result->{prepared}{errors},
    { command_id => 'command_id is required' },
    'missing thread command id is reported as validation error'
);
is( $missing_thread_command->thread_store->calls,
    0, 'missing thread command id is rejected before storage' );

my $missing_reply_command        = _workflow();
my $missing_reply_command_result = $missing_reply_command->create_reply(
    {
        thread_id      => 'thread-1',
        author_user_id => 'user-1',
        body_source    => 'reply',
    }
);
is( $missing_reply_command_result->{status},
    'invalid', 'reply write requires command id' );
is_deeply(
    $missing_reply_command_result->{prepared}{errors},
    { command_id => 'command_id is required' },
    'missing reply command id is reported as validation error'
);
is( $missing_reply_command->post_store->calls,
    0, 'missing reply command id is rejected before storage' );

my $missing_category = _workflow(
    category_reader => GPForum::Test::CategoryReader->new( found => 0 ) );
is_deeply(
    $missing_category->create_thread(
        {
            category_id    => 'missing',
            author_user_id => 'user-1',
            command_id     => 'thread-missing-category-command',
        }
    ),
    {
        error    => 'category not found',
        ok       => 0,
        prepared => undef,
        status   => 'not_found',
        stored   => undef,
    },
    'posting workflow rejects missing thread category before composing'
);

my $invalid_thread = _workflow(
    thread_composer => GPForum::Test::ThreadComposer->new(
        result => {
            ok     => 0,
            errors => { title => 'title is required' },
            values => { title => q{} },
        }
    )
);
my $invalid_thread_result = $invalid_thread->create_thread(
    {
        category_id    => 'general',
        author_user_id => 'user-1',
        command_id     => 'thread-invalid-command',
        title          => q{},
        body_source    => 'body',
        visibility     => 'public',
    }
);
is( $invalid_thread_result->{status},
    'invalid', 'posting workflow normalizes invalid thread status' );
is_deeply(
    $invalid_thread_result->{prepared}{errors},
    { title => 'title is required' },
    'posting workflow returns prepared validation details'
);
is( $invalid_thread->thread_store->calls,
    0, 'invalid thread is rejected before storage' );

my $thread_workflow = _workflow();
my $created_thread  = $thread_workflow->create_thread(
    {
        category_id    => 'general',
        author_user_id => 'user-1',
        command_id     => 'thread-command-1',
        title          => 'Hello',
        body_source    => '  hello world  ',
        visibility     => 'public',
    }
);
ok( $created_thread->{ok}, 'posting workflow creates thread' );
is( $created_thread->{status},
    'ok', 'posting workflow normalizes successful thread status' );
ok( $created_thread->{prepared}{ok},
    'successful thread includes prepared data' );
ok( $created_thread->{stored}{ok}, 'successful thread includes stored data' );
is(
    $thread_workflow->thread_composer->last_input->{body_hash},
    sha256_hex('hello world'),
    'thread body hash is normalized'
);
is( $thread_workflow->thread_composer->last_input->{idempotency_key},
    'thread-command-1', 'thread command id reaches the composer' );
is( $thread_workflow->thread_store->calls,
    1, 'posting workflow stores created thread once' );
is( $thread_workflow->mention_store->calls,
    1, 'posting workflow records mentions for first post' );

my $guarded_thread =
  _workflow( command_idempotency => GPForum::Test::CommandIdempotency->new );
my $guarded_thread_result = $guarded_thread->create_thread(
    {
        category_id    => 'general',
        author_user_id => 'user-1',
        command_id     => 'thread-command-2',
        title          => 'Hello',
        body_source    => 'body',
        visibility     => 'public',
    }
);
ok( $guarded_thread_result->{ok},
    'posting workflow creates an idempotent thread command' );
is( $guarded_thread->command_idempotency->last_input->{command_type},
    'thread.create', 'thread command idempotency records command type' );
is( $guarded_thread->command_idempotency->last_input->{command_id},
    'thread-command-2', 'thread command idempotency records command id' );
is( $guarded_thread->command_idempotency->response->{thread_id},
    'thread-1', 'thread command idempotency stores replay target' );

my $replayed_thread = _workflow(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        replay_response => {
            ok        => 1,
            post_id   => 'post-original',
            status    => 'ok',
            thread_id => 'thread-original',
        }
    )
);
my $replayed_thread_result = $replayed_thread->create_thread(
    {
        category_id    => 'general',
        author_user_id => 'user-1',
        command_id     => 'thread-command-3',
        title          => 'Hello',
        body_source    => 'body',
        visibility     => 'public',
    }
);
ok( $replayed_thread_result->{ok}, 'thread command replay returns ok' );
ok(
    $replayed_thread_result->{idempotent},
    'thread command replay is marked idempotent'
);
is( $replayed_thread_result->{stored}{thread}{thread_id},
    'thread-original', 'thread command replay returns original thread id' );
is( $replayed_thread->thread_store->calls,
    0, 'thread command replay does not call store' );
is( $replayed_thread->mention_store->calls,
    0, 'thread command replay does not record mentions again' );

my $conflicting_thread = _workflow( command_idempotency =>
      GPForum::Test::CommandIdempotency->new( conflict => 1 ) );
is(
    $conflicting_thread->create_thread(
        {
            category_id    => 'general',
            author_user_id => 'user-1',
            command_id     => 'thread-command-4',
            title          => 'Hello',
            body_source    => 'body',
            visibility     => 'public',
        }
    )->{status},
    'conflict',
    'thread command idempotency conflict is surfaced'
);

my $thread_store_failure =
  _workflow( thread_store => GPForum::Test::ThreadStore->new( fail => 1 ) );
my $thread_store_failure_result = $thread_store_failure->create_thread(
    {
        category_id    => 'general',
        author_user_id => 'user-1',
        command_id     => 'thread-store-failure-command',
        title          => 'Hello',
        body_source    => 'body',
        visibility     => 'public',
    }
);
is( $thread_store_failure_result->{status},
    'failed', 'posting workflow normalizes thread store failures' );
is(
    $thread_store_failure_result->{error},
    'thread store failed',
    'posting workflow returns thread store error'
);

my $missing_reply = _workflow( thread_detail_reader =>
      GPForum::Test::ThreadDetailReader->new( thread => undef ) );
is(
    $missing_reply->create_reply(
        {
            thread_id      => 'missing',
            author_user_id => 'user-1',
            body_source    => 'reply',
            command_id     => 'reply-missing-thread-command',
        }
    )->{status},
    'not_found',
    'posting workflow rejects replies to missing threads'
);

my $locked_reply = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => { locked_at => 'now' }
    )
);
is_deeply(
    $locked_reply->create_reply(
        {
            thread_id      => 'thread-1',
            author_user_id => 'user-1',
            body_source    => 'reply',
            command_id     => 'reply-locked-command',
        }
    ),
    {
        error    => 'thread is locked',
        ok       => 0,
        prepared => undef,
        status   => 'forbidden',
        stored   => undef,
    },
    'posting workflow rejects replies to locked threads'
);
is( $locked_reply->post_store->calls,
    0, 'locked reply is rejected before storage' );

my $reply_workflow = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => {
            category_visibility => 'members',
            space_visibility    => 'public',
            thread_id           => 'thread-1',
            visibility          => 'public',
        }
    )
);
my $created_reply = $reply_workflow->create_reply(
    {
        thread_id      => 'thread-1',
        author_user_id => 'user-2',
        body_source    => ' reply body ',
        command_id     => 'reply-command-1',
    }
);
ok( $created_reply->{ok}, 'posting workflow creates reply' );
is( $created_reply->{status},
    'ok', 'posting workflow normalizes successful reply status' );
is( $reply_workflow->post_composer->last_input->{allocate_position},
    1, 'reply workflow defers post position allocation to store' );
is( $reply_workflow->post_composer->last_input->{visibility_floor},
    'members',
    'a reply may be no broader than its thread\'s effective visibility' );
is( $reply_workflow->post_composer->last_input->{idempotency_key},
    'reply-command-1', 'reply command id reaches the composer' );
is( $reply_workflow->mention_store->last_input->{thread_id},
    'thread-1', 'reply mention recording carries thread id' );

my $replayed_reply = _workflow(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        replay_response => {
            ok        => 1,
            post_id   => 'post-original',
            status    => 'ok',
            thread_id => 'thread-1',
        }
    )
);
my $replayed_reply_result = $replayed_reply->create_reply(
    {
        thread_id      => 'thread-1',
        author_user_id => 'user-2',
        body_source    => 'reply body',
        command_id     => 'reply-command-2',
    }
);
ok( $replayed_reply_result->{ok}, 'reply command replay returns ok' );
ok(
    $replayed_reply_result->{idempotent},
    'reply command replay is marked idempotent'
);
is( $replayed_reply_result->{stored}{post}{post_id},
    'post-original', 'reply command replay returns original post id' );
is( $replayed_reply->post_store->calls,
    0, 'reply command replay does not call store' );
is( $replayed_reply->mention_store->calls,
    0, 'reply command replay does not record mentions again' );

my $invalid_reply = _workflow(
    post_composer => GPForum::Test::PostComposer->new(
        result => {
            ok     => 0,
            errors => { body_source => 'body is required' },
            values => { body_source => q{} },
        }
    )
);
is(
    $invalid_reply->create_reply(
        {
            thread_id      => 'thread-1',
            author_user_id => 'user-1',
            command_id     => 'reply-invalid-command',
        }
    )->{status},
    'invalid',
    'posting workflow normalizes invalid reply status'
);
is( $invalid_reply->post_store->calls,
    0, 'invalid reply is rejected before storage' );

my $post_store_failure =
  _workflow( post_store => GPForum::Test::PostStore->new( fail => 1 ) );
my $post_store_failure_result = $post_store_failure->create_reply(
    {
        thread_id      => 'thread-1',
        author_user_id => 'user-1',
        body_source    => 'reply',
        command_id     => 'reply-store-failure-command',
    }
);
is( $post_store_failure_result->{status},
    'failed', 'posting workflow normalizes post store failures' );
is(
    $post_store_failure_result->{error},
    'post store failed',
    'posting workflow returns post store error'
);

# A moderator can lock or hide the thread after the workflow's check; the
# store then refuses under its thread lock, and that refusal is an answer.
_assert_reply_store_refusal( 'thread is locked', 'forbidden' );
_assert_reply_store_refusal( 'thread not found', 'not_found' );

my $logger           = GPForum::Test::Logger->new;
my $mention_degraded = _workflow(
    logger        => $logger,
    mention_store => GPForum::Test::MentionStore->new( fail => 1 ),
);
my $mention_degraded_result = $mention_degraded->create_reply(
    {
        thread_id      => 'thread-1',
        author_user_id => 'user-1',
        body_source    => '@user hello',
        command_id     => 'reply-mention-degraded-command',
    }
);
ok( $mention_degraded_result->{ok},
    'posting workflow keeps persisted reply successful when mentions degrade' );
is( $logger->warnings, 1, 'posting workflow logs degraded mention recording' );

my $missing_edit =
  _workflow( post_reader => GPForum::Test::PostReader->new( post => undef ) );
is(
    $missing_edit->edit_post(
        {
            author_user_id => 'user-1',
            body_source    => 'edited',
            command_id     => 'edit-missing-command',
            post_id        => 'missing',
        }
    )->{status},
    'not_found',
    'posting workflow rejects edits to missing posts'
);

my $foreign_edit = _workflow();
is(
    $foreign_edit->edit_post(
        {
            author_user_id => 'user-2',
            body_source    => 'edited',
            command_id     => 'edit-foreign-command',
            post_id        => 'post-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects edits by non-authors'
);

my $hidden_edit = _workflow(
    post_reader => GPForum::Test::PostReader->new(
        post => {
            author_user_id   => 'user-1',
            hidden_at        => 'now',
            moderation_state => 'hidden',
            post_id          => 'post-1',
            thread_id        => 'thread-1',
        }
    )
);
is(
    $hidden_edit->edit_post(
        {
            author_user_id => 'user-1',
            body_source    => 'edited',
            command_id     => 'edit-hidden-command',
            post_id        => 'post-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects edits to hidden posts'
);

my $locked_edit = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => { locked_at => 'now', thread_id => 'thread-1' }
    )
);
is(
    $locked_edit->edit_post(
        {
            author_user_id => 'user-1',
            body_source    => 'edited',
            command_id     => 'edit-locked-command',
            post_id        => 'post-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects edits on locked threads'
);
is( $locked_edit->post_store->calls,
    0, 'locked edit is rejected before storage' );

my $edited = _workflow()->edit_post(
    {
        author_user_id => 'user-1',
        body_source    => ' edited body ',
        command_id     => 'edit-command-1',
        post_id        => 'post-1',
    }
);
ok( $edited->{ok}, 'posting workflow edits an author post' );
is( $edited->{status}, 'ok', 'posting workflow normalizes successful edit' );
is( $edited->{stored}{post}{post_id},
    'post-1', 'posting workflow returns the edited post id' );

my $replayed_edit = _workflow(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        replay_response => {
            ok        => 1,
            post_id   => 'post-original',
            status    => 'ok',
            thread_id => 'thread-original',
        }
    )
);
my $replayed_edit_result = $replayed_edit->edit_post(
    {
        author_user_id => 'user-1',
        body_source    => 'edited',
        command_id     => 'edit-replay-command',
        post_id        => 'post-1',
    }
);
ok( $replayed_edit_result->{ok}, 'posting workflow replays completed edits' );
is( $replayed_edit_result->{stored}{post}{post_id},
    'post-original', 'replayed edit returns the original post id' );
is( $replayed_edit->post_store->calls,
    0, 'replayed edit does not persist again' );

my $edit_store_failure =
  _workflow( post_store => GPForum::Test::PostStore->new( fail => 1 ) );
is(
    $edit_store_failure->edit_post(
        {
            author_user_id => 'user-1',
            body_source    => 'edited',
            command_id     => 'edit-fail-command',
            post_id        => 'post-1',
        }
    )->{status},
    'failed',
    'posting workflow normalizes post edit store failures'
);

my $missing_delete =
  _workflow( post_reader => GPForum::Test::PostReader->new( post => undef ) );
is(
    $missing_delete->delete_post(
        {
            author_user_id => 'user-1',
            command_id     => 'delete-missing-command',
            post_id        => 'missing',
        }
    )->{status},
    'not_found',
    'posting workflow rejects deletes of missing posts'
);

my $foreign_delete = _workflow();
is(
    $foreign_delete->delete_post(
        {
            author_user_id => 'user-2',
            command_id     => 'delete-foreign-command',
            post_id        => 'post-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects deletes by non-authors'
);

my $hidden_delete = _workflow(
    post_reader => GPForum::Test::PostReader->new(
        post => {
            author_user_id   => 'user-1',
            hidden_at        => 'now',
            moderation_state => 'hidden',
            post_id          => 'post-1',
            thread_id        => 'thread-1',
        }
    )
);
is(
    $hidden_delete->delete_post(
        {
            author_user_id => 'user-1',
            command_id     => 'delete-hidden-command',
            post_id        => 'post-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects deletes of hidden posts'
);

my $locked_delete = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => { locked_at => 'now', thread_id => 'thread-1' }
    )
);
is(
    $locked_delete->delete_post(
        {
            author_user_id => 'user-1',
            command_id     => 'delete-locked-command',
            post_id        => 'post-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects deletes on locked threads'
);
is( $locked_delete->post_store->calls,
    0, 'locked delete is rejected before storage' );

my $deleted = _workflow()->delete_post(
    {
        author_user_id => 'user-1',
        command_id     => 'delete-command-1',
        post_id        => 'post-1',
    }
);
ok( $deleted->{ok}, 'posting workflow deletes an author post' );
is( $deleted->{status}, 'ok', 'posting workflow normalizes successful delete' );
is( $deleted->{stored}{post}{post_id},
    'post-1', 'posting workflow returns the deleted post id' );

my $replayed_delete = _workflow(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        replay_response => {
            ok        => 1,
            post_id   => 'post-original',
            status    => 'ok',
            thread_id => 'thread-original',
        }
    )
);
my $replayed_delete_result = $replayed_delete->delete_post(
    {
        author_user_id => 'user-1',
        command_id     => 'delete-replay-command',
        post_id        => 'post-1',
    }
);
ok( $replayed_delete_result->{ok},
    'posting workflow replays completed deletes' );
is( $replayed_delete_result->{stored}{post}{post_id},
    'post-original', 'replayed delete returns the original post id' );
is( $replayed_delete->post_store->calls,
    0, 'replayed delete does not persist again' );

my $delete_store_failure =
  _workflow( post_store => GPForum::Test::PostStore->new( fail => 1 ) );
is(
    $delete_store_failure->delete_post(
        {
            author_user_id => 'user-1',
            command_id     => 'delete-fail-command',
            post_id        => 'post-1',
        }
    )->{status},
    'failed',
    'posting workflow normalizes post delete store failures'
);

my $live_restore = _workflow();
is(
    $live_restore->restore_post(
        {
            author_user_id => 'user-1',
            command_id     => 'restore-live-command',
            post_id        => 'post-1',
        }
    )->{status},
    'not_found',
    'posting workflow rejects restore of a live post'
);

my $missing_restore =
  _workflow( post_reader => GPForum::Test::PostReader->new( post => undef ) );
is(
    $missing_restore->restore_post(
        {
            author_user_id => 'user-1',
            command_id     => 'restore-missing-command',
            post_id        => 'missing',
        }
    )->{status},
    'not_found',
    'posting workflow rejects restore of a missing post'
);

my $foreign_restore = _workflow(
    post_reader => GPForum::Test::PostReader->new( post => _deleted_post() ) );
is(
    $foreign_restore->restore_post(
        {
            author_user_id => 'user-2',
            command_id     => 'restore-foreign-command',
            post_id        => 'post-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects restore by non-authors'
);

my $hidden_restore = _workflow(
    post_reader => GPForum::Test::PostReader->new(
        post => {
            %{ _deleted_post() },
            hidden_at        => 'now',
            moderation_state => 'hidden',
        }
    )
);
is(
    $hidden_restore->restore_post(
        {
            author_user_id => 'user-1',
            command_id     => 'restore-hidden-command',
            post_id        => 'post-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects restore of a hidden post'
);

my $locked_restore = _workflow(
    post_reader => GPForum::Test::PostReader->new( post => _deleted_post() ),
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => { locked_at => 'now', thread_id => 'thread-1' }
    )
);
is(
    $locked_restore->restore_post(
        {
            author_user_id => 'user-1',
            command_id     => 'restore-locked-command',
            post_id        => 'post-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects restore on a locked thread'
);
is( $locked_restore->post_store->calls,
    0, 'locked restore is rejected before storage' );

my $restored = _workflow(
    post_reader => GPForum::Test::PostReader->new( post => _deleted_post() ) )
  ->restore_post(
    {
        author_user_id => 'user-1',
        command_id     => 'restore-command-1',
        post_id        => 'post-1',
    }
  );
ok( $restored->{ok}, 'posting workflow restores an author post' );
is( $restored->{status}, 'ok',
    'posting workflow normalizes successful restore' );
is( $restored->{stored}{post}{post_id},
    'post-1', 'posting workflow returns the restored post id' );

my $replayed_restore = _workflow(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        replay_response => {
            ok        => 1,
            post_id   => 'post-original',
            status    => 'ok',
            thread_id => 'thread-original',
        }
    ),
    post_reader => GPForum::Test::PostReader->new( post => _deleted_post() ),
);
my $replayed_restore_result = $replayed_restore->restore_post(
    {
        author_user_id => 'user-1',
        command_id     => 'restore-replay-command',
        post_id        => 'post-1',
    }
);
ok( $replayed_restore_result->{ok},
    'posting workflow replays completed restores' );
is( $replayed_restore_result->{stored}{post}{post_id},
    'post-original', 'replayed restore returns the original post id' );
is( $replayed_restore->post_store->calls,
    0, 'replayed restore does not persist again' );

my $restore_store_failure = _workflow(
    post_reader => GPForum::Test::PostReader->new( post => _deleted_post() ),
    post_store  => GPForum::Test::PostStore->new( fail => 1 ),
);
is(
    $restore_store_failure->restore_post(
        {
            author_user_id => 'user-1',
            command_id     => 'restore-fail-command',
            post_id        => 'post-1',
        }
    )->{status},
    'failed',
    'posting workflow normalizes post restore store failures'
);

my $missing_title_edit = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => undef
    )
);
is(
    $missing_title_edit->edit_thread(
        {
            author_user_id => 'user-1',
            command_id     => 'thread-edit-missing-command',
            thread_id      => 'missing',
            title          => 'Edited',
        }
    )->{status},
    'not_found',
    'posting workflow rejects title edits to missing threads'
);

my $foreign_title_edit = _workflow();
is(
    $foreign_title_edit->edit_thread(
        {
            author_user_id => 'user-2',
            command_id     => 'thread-edit-foreign-command',
            thread_id      => 'thread-1',
            title          => 'Edited',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects title edits by non-authors'
);

my $hidden_title_edit = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => {
            author_user_id   => 'user-1',
            moderation_state => 'hidden',
            thread_id        => 'thread-1',
        }
    )
);
is(
    $hidden_title_edit->edit_thread(
        {
            author_user_id => 'user-1',
            command_id     => 'thread-edit-hidden-command',
            thread_id      => 'thread-1',
            title          => 'Edited',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects title edits to hidden threads'
);

my $locked_title_edit = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => {
            author_user_id => 'user-1',
            locked_at      => 'now',
            thread_id      => 'thread-1',
        }
    )
);
is(
    $locked_title_edit->edit_thread(
        {
            author_user_id => 'user-1',
            command_id     => 'thread-edit-locked-command',
            thread_id      => 'thread-1',
            title          => 'Edited',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects title edits on locked threads'
);
is( $locked_title_edit->thread_store->calls,
    0, 'locked title edit is rejected before storage' );

my $edited_thread = _workflow()->edit_thread(
    {
        author_user_id => 'user-1',
        command_id     => 'thread-edit-command-1',
        thread_id      => 'thread-1',
        title          => 'Edited Welcome',
    }
);
ok( $edited_thread->{ok}, 'posting workflow edits an author thread title' );
is( $edited_thread->{status},
    'ok', 'posting workflow normalizes successful thread edit' );
is( $edited_thread->{stored}{thread}{thread_id},
    'thread-1', 'posting workflow returns the edited thread id' );

my $replayed_title = _workflow(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        replay_response => {
            ok        => 1,
            slug      => 'original-slug',
            status    => 'ok',
            thread_id => 'thread-original',
            title     => 'Original title',
        }
    )
);
my $replayed_title_result = $replayed_title->edit_thread(
    {
        author_user_id => 'user-1',
        command_id     => 'thread-edit-replay-command',
        thread_id      => 'thread-1',
        title          => 'Edited',
    }
);
ok( $replayed_title_result->{ok},
    'posting workflow replays completed thread edits' );
is( $replayed_title_result->{stored}{thread}{thread_id},
    'thread-original', 'replayed thread edit returns the original thread id' );
is( $replayed_title->thread_store->calls,
    0, 'replayed thread edit does not persist again' );

my $title_store_failure =
  _workflow( thread_store => GPForum::Test::ThreadStore->new( fail => 1 ) );
is(
    $title_store_failure->edit_thread(
        {
            author_user_id => 'user-1',
            command_id     => 'thread-edit-fail-command',
            thread_id      => 'thread-1',
            title          => 'Edited',
        }
    )->{status},
    'failed',
    'posting workflow normalizes thread edit store failures'
);

my $missing_thread_delete = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => undef
    )
);
is(
    $missing_thread_delete->delete_thread(
        {
            author_user_id => 'user-1',
            command_id     => 'thread-delete-missing-command',
            thread_id      => 'missing',
        }
    )->{status},
    'not_found',
    'posting workflow rejects deletes of missing threads'
);

my $foreign_thread_delete = _workflow();
is(
    $foreign_thread_delete->delete_thread(
        {
            author_user_id => 'user-2',
            command_id     => 'thread-delete-foreign-command',
            thread_id      => 'thread-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects thread deletes by non-authors'
);

my $hidden_thread_delete = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => {
            author_user_id   => 'user-1',
            moderation_state => 'hidden',
            thread_id        => 'thread-1',
        }
    )
);
is(
    $hidden_thread_delete->delete_thread(
        {
            author_user_id => 'user-1',
            command_id     => 'thread-delete-hidden-command',
            thread_id      => 'thread-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects deletes of hidden threads'
);

my $locked_thread_delete = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => {
            author_user_id => 'user-1',
            locked_at      => 'now',
            thread_id      => 'thread-1',
        }
    )
);
is(
    $locked_thread_delete->delete_thread(
        {
            author_user_id => 'user-1',
            command_id     => 'thread-delete-locked-command',
            thread_id      => 'thread-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects thread deletes on locked threads'
);
is( $locked_thread_delete->thread_store->calls,
    0, 'locked thread delete is rejected before storage' );

my $deleted_thread = _workflow()->delete_thread(
    {
        author_user_id => 'user-1',
        command_id     => 'thread-delete-command-1',
        thread_id      => 'thread-1',
    }
);
ok( $deleted_thread->{ok}, 'posting workflow deletes an author thread' );
is( $deleted_thread->{status},
    'ok', 'posting workflow normalizes successful thread delete' );
is( $deleted_thread->{stored}{thread}{thread_id},
    'thread-1', 'posting workflow returns the deleted thread id' );

my $replayed_thread_delete = _workflow(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        replay_response => {
            ok        => 1,
            status    => 'ok',
            thread_id => 'thread-original',
        }
    )
);
my $replayed_thread_delete_result = $replayed_thread_delete->delete_thread(
    {
        author_user_id => 'user-1',
        command_id     => 'thread-delete-replay-command',
        thread_id      => 'thread-1',
    }
);
ok( $replayed_thread_delete_result->{ok},
    'posting workflow replays completed thread deletes' );
is( $replayed_thread_delete_result->{stored}{thread}{thread_id},
    'thread-original',
    'replayed thread delete returns the original thread id' );
is( $replayed_thread_delete->thread_store->calls,
    0, 'replayed thread delete does not persist again' );

my $thread_delete_store_failure =
  _workflow( thread_store => GPForum::Test::ThreadStore->new( fail => 1 ) );
is(
    $thread_delete_store_failure->delete_thread(
        {
            author_user_id => 'user-1',
            command_id     => 'thread-delete-fail-command',
            thread_id      => 'thread-1',
        }
    )->{status},
    'failed',
    'posting workflow normalizes thread delete store failures'
);

my $live_thread_restore = _workflow();
is(
    $live_thread_restore->restore_thread(
        {
            author_user_id => 'user-1',
            command_id     => 'thread-restore-live-command',
            thread_id      => 'thread-1',
        }
    )->{status},
    'not_found',
    'posting workflow rejects restore of a live thread'
);

my $missing_thread_restore = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => undef
    )
);
is(
    $missing_thread_restore->restore_thread(
        {
            author_user_id => 'user-1',
            command_id     => 'thread-restore-missing-command',
            thread_id      => 'missing',
        }
    )->{status},
    'not_found',
    'posting workflow rejects restore of a missing thread'
);

my $foreign_thread_restore = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => _deleted_thread()
    )
);
is(
    $foreign_thread_restore->restore_thread(
        {
            author_user_id => 'user-2',
            command_id     => 'thread-restore-foreign-command',
            thread_id      => 'thread-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects thread restore by non-authors'
);

my $hidden_thread_restore = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => {
            %{ _deleted_thread() }, moderation_state => 'hidden',
        }
    )
);
is(
    $hidden_thread_restore->restore_thread(
        {
            author_user_id => 'user-1',
            command_id     => 'thread-restore-hidden-command',
            thread_id      => 'thread-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects restore of a hidden thread'
);

my $locked_thread_restore = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => {
            %{ _deleted_thread() }, locked_at => 'now',
        }
    )
);
is(
    $locked_thread_restore->restore_thread(
        {
            author_user_id => 'user-1',
            command_id     => 'thread-restore-locked-command',
            thread_id      => 'thread-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects thread restore on a locked thread'
);
is( $locked_thread_restore->thread_store->calls,
    0, 'locked thread restore is rejected before storage' );

my $restored_thread = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => _deleted_thread()
    )
)->restore_thread(
    {
        author_user_id => 'user-1',
        command_id     => 'thread-restore-command-1',
        thread_id      => 'thread-1',
    }
);
ok( $restored_thread->{ok}, 'posting workflow restores an author thread' );
is( $restored_thread->{status},
    'ok', 'posting workflow normalizes successful thread restore' );
is( $restored_thread->{stored}{thread}{thread_id},
    'thread-1', 'posting workflow returns the restored thread id' );

my $replayed_thread_restore = _workflow(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        replay_response => {
            ok        => 1,
            status    => 'ok',
            thread_id => 'thread-original',
        }
    ),
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => _deleted_thread()
    ),
);
my $replayed_thread_restore_result = $replayed_thread_restore->restore_thread(
    {
        author_user_id => 'user-1',
        command_id     => 'thread-restore-replay-command',
        thread_id      => 'thread-1',
    }
);
ok( $replayed_thread_restore_result->{ok},
    'posting workflow replays completed thread restores' );
is( $replayed_thread_restore_result->{stored}{thread}{thread_id},
    'thread-original',
    'replayed thread restore returns the original thread id' );
is( $replayed_thread_restore->thread_store->calls,
    0, 'replayed thread restore does not persist again' );

my $thread_restore_store_failure = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => _deleted_thread()
    ),
    thread_store => GPForum::Test::ThreadStore->new( fail => 1 ),
);
is(
    $thread_restore_store_failure->restore_thread(
        {
            author_user_id => 'user-1',
            command_id     => 'thread-restore-fail-command',
            thread_id      => 'thread-1',
        }
    )->{status},
    'failed',
    'posting workflow normalizes thread restore store failures'
);

my $missing_thread_move = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => undef
    )
);
is(
    $missing_thread_move->move_thread(
        {
            author_user_id => 'user-1',
            category_id    => 'category-2',
            command_id     => 'thread-move-missing-command',
            thread_id      => 'missing',
        }
    )->{status},
    'not_found',
    'posting workflow rejects moves of missing threads'
);

my $foreign_thread_move = _workflow();
is(
    $foreign_thread_move->move_thread(
        {
            author_user_id => 'user-2',
            category_id    => 'category-2',
            command_id     => 'thread-move-foreign-command',
            thread_id      => 'thread-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects thread moves by non-authors'
);

my $missing_move_category = _workflow(
    category_reader => GPForum::Test::CategoryReader->new( found => 0 ) );
is(
    $missing_move_category->move_thread(
        {
            author_user_id => 'user-1',
            category_id    => 'category-missing',
            command_id     => 'thread-move-category-command',
            thread_id      => 'thread-1',
        }
    )->{status},
    'not_found',
    'posting workflow rejects moves to missing categories'
);

my $locked_thread_move = _workflow(
    thread_detail_reader => GPForum::Test::ThreadDetailReader->new(
        thread => {
            author_user_id => 'user-1',
            locked_at      => 'now',
            thread_id      => 'thread-1',
        }
    )
);
is(
    $locked_thread_move->move_thread(
        {
            author_user_id => 'user-1',
            category_id    => 'category-2',
            command_id     => 'thread-move-locked-command',
            thread_id      => 'thread-1',
        }
    )->{status},
    'forbidden',
    'posting workflow rejects thread moves on locked threads'
);
is( $locked_thread_move->thread_store->calls,
    0, 'locked thread move is rejected before storage' );

my $moved_thread = _workflow()->move_thread(
    {
        author_user_id => 'user-1',
        category_id    => 'category-2',
        command_id     => 'thread-move-command-1',
        thread_id      => 'thread-1',
    }
);
ok( $moved_thread->{ok}, 'posting workflow moves an author thread' );
is( $moved_thread->{status},
    'ok', 'posting workflow normalizes successful thread move' );
is( $moved_thread->{stored}{thread}{category_id},
    'category-2', 'posting workflow returns the destination category' );

my $replayed_thread_move = _workflow(
    command_idempotency => GPForum::Test::CommandIdempotency->new(
        replay_response => {
            category_id => 'category-original',
            ok          => 1,
            status      => 'ok',
            thread_id   => 'thread-original',
        }
    )
);
my $replayed_thread_move_result = $replayed_thread_move->move_thread(
    {
        author_user_id => 'user-1',
        category_id    => 'category-2',
        command_id     => 'thread-move-replay-command',
        thread_id      => 'thread-1',
    }
);
ok( $replayed_thread_move_result->{ok},
    'posting workflow replays completed thread moves' );
is( $replayed_thread_move_result->{stored}{thread}{thread_id},
    'thread-original', 'replayed thread move returns the original thread id' );
is( $replayed_thread_move->thread_store->calls,
    0, 'replayed thread move does not persist again' );

my $thread_move_store_failure =
  _workflow( thread_store => GPForum::Test::ThreadStore->new( fail => 1 ) );
is(
    $thread_move_store_failure->move_thread(
        {
            author_user_id => 'user-1',
            category_id    => 'category-2',
            command_id     => 'thread-move-fail-command',
            thread_id      => 'thread-1',
        }
    )->{status},
    'failed',
    'posting workflow normalizes thread move store failures'
);

done_testing();

sub _workflow {
    my (%override) = @_;

    return GPForum::Service::Forum::PostingWorkflow->new(
        category_reader => _workflow_component(
            \%override, 'category_reader',
            sub { return GPForum::Test::CategoryReader->new( found => 1 ); }
        ),
        command_idempotency => $override{command_idempotency},
        logger              => _workflow_component(
            \%override, 'logger',
            sub { return GPForum::Test::Logger->new(); }
        ),
        mention_store => _workflow_component(
            \%override, 'mention_store',
            sub { return GPForum::Test::MentionStore->new(); }
        ),
        post_composer => _workflow_component(
            \%override, 'post_composer',
            sub { return GPForum::Test::PostComposer->new(); }
        ),
        post_reader => _workflow_component(
            \%override,
            'post_reader',
            sub {
                return GPForum::Test::PostReader->new(
                    post => {
                        author_user_id   => 'user-1',
                        moderation_state => 'visible',
                        post_id          => 'post-1',
                        thread_id        => 'thread-1',
                    }
                );
            }
        ),
        post_store => _workflow_component(
            \%override,
            'post_store',
            sub { return GPForum::Test::PostStore->new(); }
        ),
        thread_composer => _workflow_component(
            \%override,
            'thread_composer',
            sub { return GPForum::Test::ThreadComposer->new(); }
        ),
        thread_detail_reader => _workflow_component(
            \%override,
            'thread_detail_reader',
            sub {
                return GPForum::Test::ThreadDetailReader->new(
                    thread => {
                        author_user_id => 'user-1',
                        thread_id      => 'thread-1',
                        visibility     => 'public',
                    },
                );
            }
        ),
        thread_store => _workflow_component(
            \%override,
            'thread_store',
            sub { return GPForum::Test::ThreadStore->new(); }
        ),
    );
}

sub _workflow_component {
    my ( $override, $name, $builder ) = @_;

    return $override->{$name} if exists $override->{$name};

    return $builder->();
}

# Not 'failed': a failed command is abandoned and never recorded, while a
# refusal is recorded and replayed like the workflow's own locked-thread
# answer.
sub _assert_reply_store_refusal {
    my ( $error, $status ) = @_;

    my $idempotency = GPForum::Test::CommandIdempotency->new;
    my $workflow    = _workflow(
        command_idempotency => $idempotency,
        post_store => GPForum::Test::PostStore->new( refuse => $error ),
    );
    is_deeply(
        $workflow->create_reply(
            {
                thread_id      => 'thread-1',
                author_user_id => 'user-1',
                body_source    => 'reply',
                command_id     => "reply-refused-$status-command",
            }
        ),
        {
            error    => $error,
            ok       => 0,
            prepared => undef,
            status   => $status,
            stored   => undef,
        },
        "a reply the store refuses with '$error' is $status, not failed"
    );
    is_deeply(
        $idempotency->response,
        { error => $error, ok => 0, status => $status },
        "the '$error' refusal is recorded as the command's answer"
    );
    is( $workflow->mention_store->calls,
        0, "a reply refused with '$error' records no mentions" );

    return;
}

sub _deleted_post {
    return {
        author_user_id   => 'user-1',
        deleted_at       => 'now',
        moderation_state => 'visible',
        post_id          => 'post-1',
        thread_id        => 'thread-1',
    };
}

sub _deleted_thread {
    return {
        author_user_id   => 'user-1',
        category_id      => 'category-1',
        deleted_at       => 'now',
        moderation_state => 'visible',
        thread_id        => 'thread-1',
        visibility       => 'public',
    };
}

package GPForum::Test::CategoryReader;

sub new {
    my ( $class, %arguments ) = @_;

    return bless { found => exists $arguments{found} ? $arguments{found} : 1 },
      $class;
}

sub find_category {
    my ($self) = @_;

    return $self->{found} ? { category_id => 'general' } : undef;
}

package GPForum::Test::ThreadComposer;

sub new {
    my ( $class, %arguments ) = @_;

    return bless { last_input => undef, result => $arguments{result} }, $class;
}

sub last_input {
    my ( $self, $value ) = @_;

    $self->{last_input} = $value if @_ > 1;

    return $self->{last_input};
}

sub prepare {
    my ( $self, $input ) = @_;

    $self->last_input($input);
    return $self->{result} if $self->{result};

    return {
        ok      => 1,
        command => {
            body => { body_source => $input->{body_source} },
            post => {
                author_user_id => $input->{author_user_id},
                post_id        => 'post-1',
                thread_id      => 'thread-1',
            },
            thread => { thread_id => 'thread-1' },
        },
    };
}

sub prepare_title {
    my ( $self, $input ) = @_;

    $self->last_input($input);
    if ( $self->{result} ) {
        return $self->{result};
    }

    return {
        ok      => 1,
        command => {
            thread => {
                editor_user_id => $input->{editor_user_id},
                slug           => 'edited-welcome',
                thread_id      => $input->{thread_id},
                title          => $input->{title},
            },
        },
    };
}

sub prepare_move {
    my ( $self, $input ) = @_;

    $self->last_input($input);
    if ( $self->{result} ) {
        return $self->{result};
    }

    return {
        ok      => 1,
        command => {
            thread => {
                category_id    => $input->{category_id},
                editor_user_id => $input->{editor_user_id},
                thread_id      => $input->{thread_id},
            },
        },
    };
}

package GPForum::Test::ThreadStore;

sub new {
    my ( $class, %arguments ) = @_;

    return bless { calls => 0, fail => $arguments{fail} }, $class;
}

sub calls {
    my ( $self, $value ) = @_;

    $self->{calls} = $value if @_ > 1;

    return $self->{calls};
}

sub create_thread {
    my ($self) = @_;

    $self->calls( $self->calls + 1 );
    die "thread store failed\n" if $self->{fail};

    return {
        ok     => 1,
        post   => { author_user_id => 'user-1', post_id => 'post-1' },
        thread => { thread_id      => 'thread-1' },
    };
}

sub edit_thread {
    my ( $self, $command ) = @_;

    $self->calls( $self->calls + 1 );
    if ( $self->{fail} ) {
        die "thread store failed\n";
    }

    return {
        ok     => 1,
        thread => {
            slug      => $command->{thread}{slug},
            thread_id => $command->{thread}{thread_id},
            title     => $command->{thread}{title},
        },
    };
}

sub delete_thread {
    my ( $self, $command ) = @_;

    $self->calls( $self->calls + 1 );
    if ( $self->{fail} ) {
        die "thread store failed\n";
    }

    return {
        ok     => 1,
        thread => {
            category_id => $command->{thread}{category_id},
            thread_id   => $command->{thread}{thread_id},
        },
    };
}

sub restore_thread {
    my ( $self, $command ) = @_;

    $self->calls( $self->calls + 1 );
    if ( $self->{fail} ) {
        die "thread store failed\n";
    }

    return {
        ok     => 1,
        thread => {
            category_id => $command->{thread}{category_id},
            thread_id   => $command->{thread}{thread_id},
        },
    };
}

sub move_thread {
    my ( $self, $command ) = @_;

    $self->calls( $self->calls + 1 );
    if ( $self->{fail} ) {
        die "thread store failed\n";
    }

    return {
        ok     => 1,
        thread => {
            category_id => $command->{thread}{category_id},
            thread_id   => $command->{thread}{thread_id},
        },
    };
}

package GPForum::Test::ThreadDetailReader;

sub new {
    my ( $class, %arguments ) = @_;

    return bless { thread => $arguments{thread} }, $class;
}

sub thread {
    my ($self) = @_;

    return $self->{thread};
}

sub find_thread {
    my ($self) = @_;

    return $self->thread;
}

sub find_thread_row {
    my ($self) = @_;

    return $self->thread;
}

package GPForum::Test::PostComposer;

sub new {
    my ( $class, %arguments ) = @_;

    return bless { last_input => undef, result => $arguments{result} }, $class;
}

sub last_input {
    my ( $self, $value ) = @_;

    $self->{last_input} = $value if @_ > 1;

    return $self->{last_input};
}

sub prepare {
    my ( $self, $input ) = @_;

    $self->last_input($input);
    return $self->{result} if $self->{result};

    return {
        ok      => 1,
        command => {
            body => { body_source => $input->{body_source} },
            post => {
                author_user_id => $input->{author_user_id},
                post_id        => 'post-2',
                thread_id      => $input->{thread_id},
            },
        },
    };
}

sub prepare_revision {
    my ( $self, $input ) = @_;

    $self->last_input($input);
    return $self->{result} if $self->{result};

    return {
        ok      => 1,
        command => {
            body => { body_source => $input->{body_source} },
            post => {
                editor_user_id => $input->{editor_user_id},
                post_id        => $input->{post_id},
                thread_id      => $input->{thread_id},
            },
        },
    };
}

package GPForum::Test::PostStore;

sub new {
    my ( $class, %arguments ) = @_;

    return bless {
        calls  => 0,
        fail   => $arguments{fail},
        refuse => $arguments{refuse},
    }, $class;
}

sub calls {
    my ( $self, $value ) = @_;

    $self->{calls} = $value if @_ > 1;

    return $self->{calls};
}

sub create_post {
    my ( $self, $command ) = @_;

    $self->calls( $self->calls + 1 );
    die "post store failed\n" if $self->{fail};

    # What PostStore answers when the thread lock finds the thread locked,
    # hidden or gone: a refusal, not an exception.
    return { ok => 0, error => $self->{refuse} } if $self->{refuse};

    return {
        ok   => 1,
        post => {
            author_user_id => $command->{post}{author_user_id},
            post_id        => $command->{post}{post_id},
            thread_id      => $command->{post}{thread_id},
        },
    };
}

sub edit_post {
    my ( $self, $command ) = @_;

    $self->calls( $self->calls + 1 );
    die "post store failed\n" if $self->{fail};

    return {
        ok   => 1,
        post => {
            author_user_id => $command->{post}{editor_user_id},
            post_id        => $command->{post}{post_id},
            thread_id      => $command->{post}{thread_id},
        },
    };
}

sub delete_post {
    my ( $self, $command ) = @_;

    $self->calls( $self->calls + 1 );
    if ( $self->{fail} ) {
        die "post store failed\n";
    }

    return {
        ok   => 1,
        post => {
            author_user_id => $command->{post}{deleted_by},
            post_id        => $command->{post}{post_id},
            thread_id      => $command->{post}{thread_id},
        },
    };
}

sub restore_post {
    my ( $self, $command ) = @_;

    $self->calls( $self->calls + 1 );
    if ( $self->{fail} ) {
        die "post store failed\n";
    }

    return {
        ok   => 1,
        post => {
            author_user_id => $command->{post}{restored_by},
            post_id        => $command->{post}{post_id},
            thread_id      => $command->{post}{thread_id},
        },
    };
}

package GPForum::Test::MentionStore;

sub new {
    my ( $class, %arguments ) = @_;

    return bless {
        calls      => 0,
        fail       => $arguments{fail},
        last_input => undef,
    }, $class;
}

sub calls {
    my ( $self, $value ) = @_;

    $self->{calls} = $value if @_ > 1;

    return $self->{calls};
}

sub last_input {
    my ( $self, $value ) = @_;

    $self->{last_input} = $value if @_ > 1;

    return $self->{last_input};
}

sub record_for_source {
    my ( $self, $input ) = @_;

    $self->calls( $self->calls + 1 );
    $self->last_input($input);
    die "mention failed\n" if $self->{fail};

    return { ok => 1 };
}

package GPForum::Test::Logger;

sub new {
    my ($class) = @_;

    return bless { warnings => 0 }, $class;
}

sub error { return; }

sub warn {
    my ($self) = @_;

    $self->{warnings}++;

    return;
}

sub warnings {
    my ($self) = @_;

    return $self->{warnings};
}

package GPForum::Test::Cache;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

package GPForum::Test::Schema;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

package GPForum::Test::Id;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub uuid {
    return 'uuid-1';
}

package GPForum::Test::RealtimeHub;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

1;
