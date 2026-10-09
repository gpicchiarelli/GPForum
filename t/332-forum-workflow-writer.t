# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::PostStore;
use GPForum::Service::Forum::PostingWorkflow;
use GPForum::Service::Forum::ThreadStore;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::MentionLog;
use GPForum::Test::PostStoreLockDbh;
use GPForum::Test::PostStoreLockSchema;
use GPForum::Test::PostingDouble;
use GPForum::Test::RowReader;

our $VERSION = '0.001';

# The workflow trims the requester before it asks the rules, and the stores
# ask the same rules again of the requester the command names: so the
# command names the trimmed requester too, or a padded user id the workflow
# let through would be refused under the lock as someone else.

my $PADDED = '  author ';
my $WHEN   = '2026-01-01T00:00:00Z';
my $double = GPForum::Test::PostingDouble->new;

my %LIVE_POST = (
    author_user_id   => 'author',
    moderation_state => 'visible',
    post_id          => 'post-1',
    thread_id        => 'thread-1',
    version          => 1,
);
my %OPEN_THREAD = (
    author_user_id   => 'author',
    category_id      => 'general',
    locked_at        => undef,
    moderation_state => 'visible',
    slug             => 'a-thread',
    thread_id        => 'thread-1',
    title            => 'A thread',
    version          => 1,
);
my %DELETED_POST   = ( %LIVE_POST,   deleted_at => $WHEN );
my %DELETED_THREAD = ( %OPEN_THREAD, deleted_at => $WHEN );

my %POST_CASE = (
    delete_post  => [ {%LIVE_POST},    'deleted_by' ],
    restore_post => [ {%DELETED_POST}, q{restored_by} ],
);
for my $method ( sort keys %POST_CASE ) {
    my ( $post, $writer ) = @{ $POST_CASE{$method} };
    my $schema = GPForum::Test::PostStoreLockSchema->new(
        lock_dbh => GPForum::Test::PostStoreLockDbh->new(
            thread_row => {%OPEN_THREAD}
        ),
        posts => [ { %{$post} } ],
    );
    my $result = _workflow(
        reader => GPForum::Test::RowReader->new(
            post   => $post,
            thread => {%OPEN_THREAD},
            writer => 'author',
        ),
        post_store => _post_store($schema),
    )->$method( _input( post_id => 'post-1' ) );

    is( $result->{status}, 'ok',
        "$method: a padded requester is the author under the lock too" );
    is(
        $schema->posts->[0]{deleted_by},
        $method eq 'delete_post' ? 'author' : undef,
        "$method: the post records the trimmed requester"
    );
    is( $schema->created_for('EventLog')->[0]{actor_id},
        'author', "$method: the event names the trimmed requester as $writer" );
}

my %THREAD_CASE = (
    delete_thread  => {%OPEN_THREAD},
    restore_thread => {%DELETED_THREAD},
);
for my $method ( sort keys %THREAD_CASE ) {
    my $thread = $THREAD_CASE{$method};
    my $schema = GPForum::Test::PostStoreLockSchema->new(
        lock_dbh => GPForum::Test::PostStoreLockDbh->new(
            thread_row => { %{$thread} }
        ),
        threads => [ { %{$thread} } ],
    );
    my $result = _workflow(
        reader => GPForum::Test::RowReader->new(
            thread => $thread,
            writer => 'author',
        ),
        thread_store => GPForum::Service::Forum::ThreadStore->new(
            clock      => GPForum::Test::FixedClock->new,
            id_service => GPForum::Test::Id->new,
            schema     => $schema,
        ),
    )->$method( _input( thread_id => 'thread-1' ) );

    is( $result->{status}, 'ok',
        "$method: a padded requester is the author under the lock too" );
    is( $schema->created_for('EventLog')->[0]{actor_id},
        'author', "$method: the event names the trimmed requester" );
}

# The workflow's own check trims the requester before it compares authors.
for my $method (qw(edit_post delete_post)) {
    my $workflow = _workflow(
        reader => GPForum::Test::RowReader->new(
            post   => {%LIVE_POST},
            thread => {%OPEN_THREAD},
            writer => 'author',
        ),
    );
    is(
        $workflow->$method(
            _input( body_source => 'Body', post_id => 'post-1' )
        )->{status},
        'ok',
        "$method: the workflow's check trims the requester"
    );
}
for my $method (qw(edit_thread delete_thread)) {
    my $workflow = _workflow(
        reader => GPForum::Test::RowReader->new(
            thread => {%OPEN_THREAD},
            writer => 'author',
        ),
    );
    is(
        $workflow->$method( _input( thread_id => 'thread-1', title => 'New' ) )
          ->{status},
        'ok',
        "$method: the workflow's check trims the requester"
    );
}

# The mentions of a new thread, a reply and an edit are recorded; a delete
# records none.
my %MENTIONS = (
    create_reply  => 1,
    create_thread => 1,
    delete_post   => 0,
    edit_post     => 1,
);
for my $method ( sort keys %MENTIONS ) {
    my $mentions = GPForum::Test::MentionLog->new;
    my $workflow = _workflow(
        mention_store => $mentions,
        reader        => GPForum::Test::RowReader->new(
            post   => {%LIVE_POST},
            thread => {%OPEN_THREAD},
            writer => 'author',
        ),
    );
    my $result = $workflow->$method(
        _input(
            body_source => 'Hello @someone',
            category_id => 'general',
            post_id     => 'post-1',
            thread_id   => 'thread-1',
            title       => 'Title',
        )
    );
    is( $result->{status}, 'ok', "$method succeeds" );
    is( scalar @{ $mentions->calls },
        $MENTIONS{$method},
        "$method records the mentions $MENTIONS{$method} time(s)" );
}

# No input at all is input without a command id, as before the split.
for my $method (
    qw(create_thread create_reply edit_thread move_thread delete_thread
    restore_thread edit_post delete_post restore_post)
  )
{
    is(
        _workflow( reader => GPForum::Test::RowReader->new )->$method(undef)
          ->{status},
        q{invalid},
        "$method: no input is invalid"
    );
}

done_testing();

sub _input (%field) {
    return {
        author_user_id => $PADDED,
        command_id     => 'command-1',
        %field,
    };
}

sub _post_store ($schema) {
    return GPForum::Service::Forum::PostStore->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
    );
}

sub _workflow (%collaborator) {
    my $reader = delete $collaborator{reader};

    return GPForum::Service::Forum::PostingWorkflow->new(
        category_reader      => $double,
        mention_store        => $double,
        post_composer        => $double,
        post_reader          => $reader,
        post_store           => $double,
        thread_composer      => $double,
        thread_detail_reader => $reader,
        thread_store         => $double,
        %collaborator,
    );
}

1;
