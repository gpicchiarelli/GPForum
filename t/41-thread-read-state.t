package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::ReadState;
use GPForum::Service::Forum::ReadWorkflow;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::FixedClock;
use GPForum::Test::ReadStateResultSet;
use GPForum::Test::ReadStateSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS     => 39;
const my $FIRST_POSITION     => 1;
const my $SECOND_POSITION    => 2;
const my $NO_POSITION        => 0;
const my $UNREAD_POSTS       => 2;
const my $ONE_UNREAD_POST    => 1;
const my $TRANSACTION_COUNT  => 2;
const my $CREATED_STATE_ROWS => 1;
const my $CREATED_DELTA_ROWS => 1;

plan tests => $EXPECTED_TESTS;

my $state_rows = GPForum::Test::ReadStateResultSet->new;
my $delta_rows = GPForum::Test::ReadStateResultSet->new(
    unique_name => 'user_read_marker_deltas_pkey', );
my $schema = GPForum::Test::ReadStateSchema->new(
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
ok( $non_regression->{skipped},   'non-advancing read marker is skipped' );
is( $non_regression->{read_state}{last_read_position},
    $FIRST_POSITION, 'stored read position remains monotonic' );
is(
    $non_regression->{read_state}{last_read_at},
    $marked->{read_state}{last_read_at},
    'non-advancing read marker keeps the original timestamp'
);
is( $schema->transactions, $TRANSACTION_COUNT,
    'read marker writes run inside transaction boundary' );

$state_rows->find_misses(1);
my $raced = $read_state->mark_thread_read(
    {
        user_id            => 'user-1',
        thread_id          => 'thread-1',
        last_read_position => $FIRST_POSITION,
    }
);
ok( $raced->{skipped}, 'unique read-state race is skipped' );
is(
    $raced->{read_state}{last_read_at},
    $marked->{read_state}{last_read_at},
    'unique read-state race keeps the original timestamp'
);
is( scalar @{ $state_rows->created },
    $CREATED_STATE_ROWS,
    'unique read-state race does not insert another state row' );
is( scalar @{ $delta_rows->created },
    $CREATED_DELTA_ROWS,
    'unique read-state race does not insert another delta row' );

my $orphan_state = GPForum::Test::ReadStateResultSet->new;
$orphan_state->create(
    {
        last_read_at       => '2026-05-23T12:00:00Z',
        last_read_position => $FIRST_POSITION,
        thread_id          => 'thread-orphan',
        user_id            => 'user-1',
    }
);
my $orphan_delta = GPForum::Test::ReadStateResultSet->new(
    unique_name => 'user_read_marker_deltas_pkey', );
my $orphan_schema = GPForum::Test::ReadStateSchema->new(
    resultsets => {
        ThreadReadState     => $orphan_state,
        UserReadMarkerDelta => $orphan_delta,
    },
);
$orphan_state->find_misses(1);
my $orphan_read = GPForum::Service::Forum::ReadState->new(
    clock  => GPForum::Test::FixedClock->new,
    schema => $orphan_schema,
);
my $orphan = $orphan_read->mark_thread_read(
    {
        last_read_position => $FIRST_POSITION,
        thread_id          => 'thread-orphan',
        user_id            => 'user-1',
    }
);
ok( $orphan->{skipped}, 'leftover read-state race keeps this marker' );
is( $orphan->{read_state}{last_read_at},
    '2026-05-23T12:00:00Z',
    'leftover read-state race keeps the original timestamp' );
is( scalar @{ $orphan_state->created },
    1, 'leftover read-state race does not insert another state row' );
is( scalar @{ $orphan_delta->created },
    1, 'leftover read-state race inserts the missing delta' );

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

my $idempotency = GPForum::Test::CommandIdempotency->new;
my $workflow    = GPForum::Service::Forum::ReadWorkflow->new(
    command_idempotency => $idempotency,
    read_state          => $read_state,
);
my $missing_command = $workflow->mark_thread_read(
    {
        last_read_position => $FIRST_POSITION,
        thread_id          => 'thread-1',
        user_id            => 'user-1',
    }
);
is( $missing_command->{status},
    'invalid', 'read workflow rejects a missing command_id' );
is(
    $missing_command->{errors}{command_id},
    'command_id is required',
    'read workflow names the missing command_id'
);

_replay_read_marker(
    {
        commanded   => $workflow,
        idempotency => $idempotency,
        input       => {
            command_id         => 'read-replay-1',
            last_read_position => $SECOND_POSITION,
            thread_id          => 'thread-1',
            user_id            => 'user-1',
        },
        request => {
            last_read_position => $SECOND_POSITION,
            thread_id          => 'thread-1',
            user_id            => 'user-1',
        },
        rows => $state_rows,
    }
);

sub _store_writes {
    my ($rows) = @_;

    return scalar @{ $rows->created };
}

sub _replay_read_marker {
    my ($job) = @_;

    my $write_issued = $job->{commanded}->mark_thread_read( $job->{input} );
    ok( $write_issued->{ok}, 'read workflow records a command' );
    is( $job->{idempotency}->last_input->{command_type},
        'forum.read_marker', 'read workflow uses forum.read_marker' );
    is_deeply( $job->{idempotency}->last_input->{request},
        $job->{request}, 'read workflow command log stores actor and target' );
    my $write_count    = _store_writes( $job->{rows} );
    my $write_replayed = GPForum::Service::Forum::ReadWorkflow->new(
        command_idempotency => GPForum::Test::CommandIdempotency->new(
            replay_response => $write_issued,
        ),
        read_state => $job->{commanded}->read_state,
    )->mark_thread_read( $job->{input} );
    is_deeply( $write_replayed, $write_issued,
        'read workflow replays the recorded result' );
    is( _store_writes( $job->{rows} ),
        $write_count, 'read workflow replay does not persist twice' );
    my $write_conflict = GPForum::Service::Forum::ReadWorkflow->new(
        command_idempotency => GPForum::Test::CommandIdempotency->new(
            conflict => 1,
        ),
        read_state => $job->{commanded}->read_state,
    )->mark_thread_read( $job->{input} );
    is( $write_conflict->{status},
        'conflict',
        'read workflow rejects a reused command_id for another request' );

    return;
}

1;
