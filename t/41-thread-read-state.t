package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::ReadState;
use GPForum::Test::FixedClock;
use GPForum::Test::ReadStateResultSet;
use GPForum::Test::ReadStateSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS     => 21;
const my $FIRST_POSITION     => 1;
const my $SECOND_POSITION    => 2;
const my $NO_POSITION        => 0;
const my $UNREAD_POSTS       => 2;
const my $ONE_UNREAD_POST    => 1;
const my $TRANSACTION_COUNT  => 2;
const my $CREATED_STATE_ROWS => 2;
const my $CREATED_DELTA_ROWS => 2;

plan tests => $EXPECTED_TESTS;

my $state_rows = GPForum::Test::ReadStateResultSet->new;
my $delta_rows = GPForum::Test::ReadStateResultSet->new;
my $schema     = GPForum::Test::ReadStateSchema->new(
    resultsets => {
        ThreadReadState     => $state_rows,
        UserReadMarkerDelta => $delta_rows,
    },
);
my $read_state = GPForum::Service::Forum::ReadState->new(
    clock  => GPForum::Test::FixedClock->new,
    schema => $schema,
);
my $posts = [
    { post_id => 'post-1', position => $FIRST_POSITION },
    { post_id => 'post-2', position => $SECOND_POSITION },
];

my $anonymous = $read_state->summary_for_page( undef, 'thread-1', $posts );
is( $anonymous->{authenticated}, 0, 'anonymous reading summary is explicit' );
is( $anonymous->{last_visible_position},
    $SECOND_POSITION, 'anonymous summary tracks last visible position' );

my $initial = $read_state->state_for_thread( 'user-1', 'thread-1' );
is( $initial->{last_read_position},
    $NO_POSITION, 'missing read state starts at zero' );

my $summary = $read_state->summary_for_page( 'user-1', 'thread-1', $posts );
is( $summary->{authenticated},        1, 'user reading summary is explicit' );
is( $summary->{unread_in_page},       $UNREAD_POSTS, 'all posts are unread' );
is( $summary->{first_unread_post_id}, 'post-1',      'first unread is named' );
is( $summary->{first_unread_anchor},
    'post-post-1', 'first unread anchor is stable' );
is( $summary->{last_visible_position},
    $SECOND_POSITION, 'summary exposes last visible position' );

my $marked = $read_state->mark_thread_read(
    {
        user_id            => 'user-1',
        thread_id          => 'thread-1',
        last_read_position => $FIRST_POSITION,
    }
);
ok( $marked->{ok},       'read marker update succeeds' );
ok( $marked->{advanced}, 'read marker advances state' );
is( $marked->{read_state}{last_read_at},
    '2026-05-23T12:00:00Z', 'read marker stores timestamp' );
is( $state_rows->created->[0]{last_read_position},
    $FIRST_POSITION, 'thread read state is upserted' );
is( $delta_rows->created->[0]{last_read_position},
    $FIRST_POSITION, 'read marker delta is upserted' );

my $after_first = $read_state->summary_for_page( 'user-1', 'thread-1', $posts );
is( $after_first->{unread_in_page},
    $ONE_UNREAD_POST, 'summary reflects stored read position' );
is( $after_first->{first_unread_post_id},
    'post-2', 'summary jumps to next unread post' );

my $non_regression = $read_state->mark_thread_read(
    {
        user_id            => 'user-1',
        thread_id          => 'thread-1',
        last_read_position => $NO_POSITION,
    }
);
ok( !$non_regression->{advanced}, 'read marker never regresses' );
is( $non_regression->{read_state}{last_read_position},
    $FIRST_POSITION, 'stored read position remains monotonic' );
is( $schema->transactions, $TRANSACTION_COUNT,
    'read marker writes run inside transaction boundary' );

my $invalid = $read_state->mark_thread_read(
    {
        user_id            => 'user-1',
        thread_id          => 'thread-1',
        last_read_position => 'bad',
    }
);
ok( !$invalid->{ok}, 'invalid read marker is rejected' );
is( scalar @{ $state_rows->created },
    $CREATED_STATE_ROWS, 'invalid input does not write state row' );
is( scalar @{ $delta_rows->created },
    $CREATED_DELTA_ROWS, 'invalid input does not write delta row' );

1;
