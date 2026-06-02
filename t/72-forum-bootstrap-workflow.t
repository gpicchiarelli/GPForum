package main;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use Test::More;

use lib 'lib';

use GPForum::Bootstrap::Forum;
use GPForum::Config;
use GPForum::Service::Forum::PostingWorkflow;
use Mojolicious;

our $VERSION = '0.001';

can_ok( 'GPForum::Bootstrap::Forum', 'register' );
can_ok( 'GPForum::Service::Forum::PostingWorkflow',
    qw(create_reply create_thread) );

my $application = Mojolicious->new();
$application->secrets( ['bootstrap-forum-test'] );
$application->helper(
    gp_schema => sub { return GPForum::Test::Schema->new(); } );
$application->helper( gp_id => sub { return GPForum::Test::Id->new(); } );
$application->helper(
    gp_local_cache => sub { return GPForum::Test::Cache->new(); } );
$application->helper(
    gp_mention_store => sub { return GPForum::Test::MentionStore->new(); } );
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
isa_ok( $controller->gp_posting_workflow,
    'GPForum::Service::Forum::PostingWorkflow' );

my $missing_category = _workflow(
    category_reader => GPForum::Test::CategoryReader->new( found => 0 ) );
is_deeply(
    $missing_category->create_thread(
        {
            category_id    => 'missing',
            author_user_id => 'user-1',
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
is( $thread_workflow->thread_store->calls,
    1, 'posting workflow stores created thread once' );
is( $thread_workflow->mention_store->calls,
    1, 'posting workflow records mentions for first post' );

my $thread_store_failure =
  _workflow( thread_store => GPForum::Test::ThreadStore->new( fail => 1 ) );
my $thread_store_failure_result = $thread_store_failure->create_thread(
    {
        category_id    => 'general',
        author_user_id => 'user-1',
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
is( $missing_reply->create_reply( { thread_id => 'missing' } )->{status},
    'not_found', 'posting workflow rejects replies to missing threads' );

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
        thread => { thread_id => 'thread-1', visibility => 'members' }
    )
);
my $created_reply = $reply_workflow->create_reply(
    {
        thread_id      => 'thread-1',
        author_user_id => 'user-2',
        body_source    => ' reply body ',
    }
);
ok( $created_reply->{ok}, 'posting workflow creates reply' );
is( $created_reply->{status},
    'ok', 'posting workflow normalizes successful reply status' );
is( $reply_workflow->post_composer->last_input->{allocate_position},
    1, 'reply workflow defers post position allocation to store' );
is( $reply_workflow->post_composer->last_input->{visibility},
    'members', 'reply workflow inherits thread visibility by default' );
is( $reply_workflow->mention_store->last_input->{thread_id},
    'thread-1', 'reply mention recording carries thread id' );

my $invalid_reply = _workflow(
    post_composer => GPForum::Test::PostComposer->new(
        result => {
            ok     => 0,
            errors => { body_source => 'body is required' },
            values => { body_source => q{} },
        }
    )
);
is( $invalid_reply->create_reply( { thread_id => 'thread-1' } )->{status},
    'invalid', 'posting workflow normalizes invalid reply status' );
is( $invalid_reply->post_store->calls,
    0, 'invalid reply is rejected before storage' );

my $post_store_failure =
  _workflow( post_store => GPForum::Test::PostStore->new( fail => 1 ) );
my $post_store_failure_result = $post_store_failure->create_reply(
    {
        thread_id      => 'thread-1',
        author_user_id => 'user-1',
        body_source    => 'reply',
    }
);
is( $post_store_failure_result->{status},
    'failed', 'posting workflow normalizes post store failures' );
is(
    $post_store_failure_result->{error},
    'post store failed',
    'posting workflow returns post store error'
);

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
    }
);
ok( $mention_degraded_result->{ok},
    'posting workflow keeps persisted reply successful when mentions degrade' );
is( $logger->warnings, 1, 'posting workflow logs degraded mention recording' );

done_testing();

sub _workflow {
    my (%override) = @_;

    return GPForum::Service::Forum::PostingWorkflow->new(
        category_reader => $override{category_reader}
          || GPForum::Test::CategoryReader->new( found => 1 ),
        logger        => $override{logger} || GPForum::Test::Logger->new(),
        mention_store => $override{mention_store}
          || GPForum::Test::MentionStore->new(),
        post_composer => $override{post_composer}
          || GPForum::Test::PostComposer->new(),
        post_position => $override{post_position}
          || GPForum::Test::PostPosition->new(),
        post_store => $override{post_store} || GPForum::Test::PostStore->new(),
        thread_composer => $override{thread_composer}
          || GPForum::Test::ThreadComposer->new(),
        thread_detail_reader => $override{thread_detail_reader}
          || GPForum::Test::ThreadDetailReader->new(
            thread => { thread_id => 'thread-1', visibility => 'public' }
          ),
        thread_store => $override{thread_store}
          || GPForum::Test::ThreadStore->new(),
    );
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

package GPForum::Test::PostPosition;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub next_position {
    return 3;
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

package GPForum::Test::PostStore;

sub new {
    my ( $class, %arguments ) = @_;

    return bless { calls => 0, fail => $arguments{fail} }, $class;
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

    return {
        ok   => 1,
        post => {
            author_user_id => $command->{post}{author_user_id},
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
