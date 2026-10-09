# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use Mojo::Log;

use GPForum::Service::Realtime::ListenerSupervisor;
use GPForum::Test::RealtimeDyingListener;
use GPForum::Test::RealtimeSupervisorIOLoop;
use GPForum::Test::RealtimeSupervisorListener;

our $VERSION = '0.001';

# The supervisor keeps this much of a listener's message; the long error is
# longer than that.
const my $ERROR_TEXT_LIMIT  => 300;
const my $LONG_ERROR_LENGTH => 400;
const my $HEARTBEAT_SECONDS => 9;

my $ioloop     = GPForum::Test::RealtimeSupervisorIOLoop->new;
my $listener   = GPForum::Test::RealtimeSupervisorListener->new;
my $supervisor = GPForum::Service::Realtime::ListenerSupervisor->new(
    heartbeat_interval_seconds => $HEARTBEAT_SECONDS,
    ioloop                     => $ioloop,
    listener                   => $listener,
    poll_interval_seconds      => 2,
    reconnect_backoff_seconds  => 4,
);

my $start = $supervisor->start;
ok( $start->{ok}, 'supervisor starts listener' );
is( $listener->starts,                1, 'listener start is invoked once' );
is( $supervisor->snapshot->{running}, 1, 'supervisor snapshot is running' );
is( scalar @{ $ioloop->recurring_calls },
    2, 'supervisor schedules poll and heartbeat timers' );
is( scalar @{ $ioloop->finish_callbacks },
    1, 'supervisor registers IOLoop finish cleanup' );
is( $ioloop->recurring_calls->[0]{interval},
    2, 'poll interval is configurable' );
is( $ioloop->recurring_calls->[1]{interval},
    $HEARTBEAT_SECONDS, 'heartbeat interval is configurable' );

my $idempotent = $supervisor->start;
ok( $idempotent->{idempotent}, 'supervisor start is idempotent' );
is( $listener->starts, 1, 'idempotent start does not restart listener' );
is( scalar @{ $ioloop->finish_callbacks },
    1, 'idempotent start does not duplicate finish cleanup' );

my $poll = $supervisor->poll_once;
ok( $poll->{ok}, 'supervisor polls listener' );
is( $listener->polls, 1, 'listener poll is invoked' );

$listener->fail_poll(1);
my $degraded = $supervisor->poll_once;
ok( !$degraded->{ok}, 'supervisor reports degraded poll failures' );
is( $listener->reconnects, 1, 'poll failure reconnects listener' );
is( $supervisor->snapshot->{stats}{poll_failures},
    1, 'supervisor counts poll failures' );

my $stop = $supervisor->stop;
ok( $stop->{ok}, 'supervisor stops' );
is( $listener->stops, 1, 'listener stop is invoked' );
is( scalar @{ $ioloop->removed },
    2, 'supervisor removes scheduled timers on stop' );

my $finish_ioloop     = GPForum::Test::RealtimeSupervisorIOLoop->new;
my $finish_listener   = GPForum::Test::RealtimeSupervisorListener->new;
my $finish_supervisor = GPForum::Service::Realtime::ListenerSupervisor->new(
    ioloop   => $finish_ioloop,
    listener => $finish_listener,
);
$finish_supervisor->start;
$finish_ioloop->finish_callbacks->[0]->();
is( $finish_listener->stops, 1, 'IOLoop finish cleanup stops listener' );

my $disabled = GPForum::Service::Realtime::ListenerSupervisor->new(
    enabled  => 0,
    ioloop   => $ioloop,
    listener => $listener,
);
is( $disabled->start->{status},
    'disabled', 'disabled supervisor does not start listener' );

my $failing_start_listener =
  GPForum::Test::RealtimeSupervisorListener->new( fail_start => 1 );
my $failing_start = GPForum::Service::Realtime::ListenerSupervisor->new(
    ioloop   => GPForum::Test::RealtimeSupervisorIOLoop->new,
    listener => $failing_start_listener,
);
my $start_failure = $failing_start->start;
ok( !$start_failure->{ok}, 'supervisor degrades when listener cannot start' );
is( $failing_start->snapshot->{stats}{degraded},
    1, 'supervisor counts start degradation' );
is( scalar @{ $failing_start->ioloop->timer_calls },
    1, 'supervisor schedules reconnect after failed start' );
is( $failing_start->snapshot->{status},
    'degraded', 'a failed start turns the supervisor status to degraded' );
is_deeply(
    $failing_start->snapshot->{last_error},
    { during => 'start', message => 'listen_failed' },
    'a start the listener refused keeps its reason as the last error'
);

# A listener that dies, rather than answering ok => 0, used to lose its
# message: the supervisor said degraded and nothing else.
my $dying_log   = Mojo::Log->new( level => 'warn' );
my $warnings    = $dying_log->capture('warn');
my $dying_start = GPForum::Service::Realtime::ListenerSupervisor->new(
    ioloop   => GPForum::Test::RealtimeSupervisorIOLoop->new,
    listener => GPForum::Test::RealtimeDyingListener->new( die_start => 1 ),
    logger   => $dying_log,
);
my $died_start = $dying_start->start;
is( $died_start->{reason}, 'listener_failed',
    'a listener that dies on start is reported as listener_failed' );
is( $dying_start->snapshot->{status},
    'degraded',
    'a listener that died on start leaves the supervisor degraded' );
is_deeply(
    $dying_start->snapshot->{last_error},
    {
        during  => 'start',
        message => 'could not connect to server: Connection refused',
    },
    'the first line of the start error is kept as the last error'
);
my @logged = grep { length } split /\n/msx, "$warnings";
is( scalar @logged, 1, 'the start error is logged once' );
like( $logged[0], qr/\[warn\]/msx, 'the start error is logged at warn level' );
my $start_warning = 'realtime listener start failed: '
  . 'could not connect to server: Connection refused';
is( substr( $logged[0], -length $start_warning ),
    $start_warning, 'the start error is logged with its message' );
$dying_start->start;
@logged = grep { length } split /\n/msx, "$warnings";
is( scalar @logged,
    1, 'the same start error again is not logged a second time' );

my $dying_poll = GPForum::Service::Realtime::ListenerSupervisor->new(
    ioloop   => GPForum::Test::RealtimeSupervisorIOLoop->new,
    listener => GPForum::Test::RealtimeDyingListener->new( die_poll => 1 ),
);
$dying_poll->start;
my $died_poll = $dying_poll->poll_once;
is( $died_poll->{reason}, 'poll_failed',
    'a listener that dies on poll is reported as poll_failed' );
is_deeply(
    $dying_poll->snapshot->{last_error},
    {
        during  => 'poll',
        message => 'server closed the connection unexpectedly at Pg.pm line 7.',
    },
    'the poll error is kept as the last error'
);
is( $dying_poll->snapshot->{status},
    'running', 'a poll failure the reconnect repaired reads as running' );

my $dying_snapshot = GPForum::Service::Realtime::ListenerSupervisor->new(
    ioloop   => GPForum::Test::RealtimeSupervisorIOLoop->new,
    listener => GPForum::Test::RealtimeDyingListener->new( die_snapshot => 1 ),
);
$dying_snapshot->start;
my $contained;
try {
    $contained = $dying_snapshot->snapshot;
}
catch ($error) {
    $contained = undef;
};
ok( $contained, 'a listener snapshot that dies does not take /metrics down' );
is_deeply(
    $contained->{listener},
    { error => 'notification queue is gone', status => 'unavailable' },
    'the dead listener snapshot reads as unavailable, with its error'
);
is( $contained->{stats}{snapshot_failures},
    1, 'the failed listener snapshot is counted' );
is( $contained->{last_error},
    undef, 'a failed snapshot is not a failure of the listener itself' );
is( $contained->{status}, 'running',
    'a failed snapshot does not change the listener status' );
is( $disabled->snapshot->{status},
    'disabled', 'a disabled supervisor reads as disabled' );

# A listener whose poll and snapshot both die keeps its poll error. Kept in
# last_error as well, the snapshot error replaced it on every read of
# /metrics -- which reads the snapshot first -- so the reason the listener
# was degraded never reached /metrics.
my $broken = GPForum::Service::Realtime::ListenerSupervisor->new(
    ioloop   => GPForum::Test::RealtimeSupervisorIOLoop->new,
    listener => GPForum::Test::RealtimeDyingListener->new(
        die_poll      => 1,
        die_reconnect => 1,
        die_snapshot  => 1,
    ),
);
$broken->start;
$broken->poll_once;
$broken->snapshot;
my $broken_snapshot = $broken->snapshot;
is( $broken_snapshot->{status},
    'degraded', 'a listener whose poll and reconnect died reads as degraded' );
is_deeply(
    $broken_snapshot->{last_error},
    {
        during  => 'reconnect',
        message => 'FATAL:  the database system is shutting down',
    },
    'and its last error is still the listener\'s, past two failed snapshots'
);
is(
    $broken_snapshot->{listener}{error},
    'notification queue is gone',
    'while the snapshot error stays on the listener field'
);

# A second outage that fails as the first one did is logged again. Compared
# with last_error, which a recovery keeps, it was taken for a repeat of the
# first and never reached the log.
my $outage_log      = Mojo::Log->new( level => 'warn' );
my $outage_warnings = $outage_log->capture('warn');
my $outage_listener =
  GPForum::Test::RealtimeDyingListener->new( die_start => 1 );
my $outages = GPForum::Service::Realtime::ListenerSupervisor->new(
    ioloop   => GPForum::Test::RealtimeSupervisorIOLoop->new,
    listener => $outage_listener,
    logger   => $outage_log,
);
$outages->start;
$outage_listener->die_start(0);
$outages->start;
ok( $outages->poll_once->{ok}, 'the listener recovers and polls' );
$outages->stop;
$outage_listener->die_start(1);
$outages->start;
$outages->start;
my @outage_lines = grep { length } split /\n/msx, "$outage_warnings";
is( scalar @outage_lines,
    2, 'each outage is logged once, the second although its message repeats' );

# The listener's failure and its snapshot's are remembered apart: a snapshot
# error in between does not make the repeated start error look new.
my $apart_log      = Mojo::Log->new( level => 'warn' );
my $apart_warnings = $apart_log->capture('warn');
my $apart_listener = GPForum::Test::RealtimeDyingListener->new(
    die_snapshot => 1,
    die_start    => 1,
);
my $apart = GPForum::Service::Realtime::ListenerSupervisor->new(
    ioloop   => GPForum::Test::RealtimeSupervisorIOLoop->new,
    listener => $apart_listener,
    logger   => $apart_log,
);
$apart->start;
$apart->snapshot;
$apart->start;
$apart->snapshot;
my @apart_lines = grep { length } split /\n/msx, "$apart_warnings";
is( scalar @apart_lines,
    2, 'a start error and a snapshot error are each logged once' );

# A reconnect that dies keeps its own message, and the supervisor stays
# degraded and not running until a later reconnect works.
my $dying_reconnect = GPForum::Service::Realtime::ListenerSupervisor->new(
    ioloop   => GPForum::Test::RealtimeSupervisorIOLoop->new,
    listener => GPForum::Test::RealtimeDyingListener->new(
        die_poll      => 1,
        die_reconnect => 1,
    ),
);
$dying_reconnect->start;
$dying_reconnect->poll_once;
is_deeply(
    $dying_reconnect->snapshot->{last_error},
    {
        during  => 'reconnect',
        message => 'FATAL:  the database system is shutting down',
    },
    'a reconnect that dies keeps its message as the last error'
);
is( $dying_reconnect->snapshot->{status},
    'degraded', 'a reconnect that died leaves the supervisor degraded' );
is( $dying_reconnect->snapshot->{running}, 0, 'and not running' );

# The message is the first line that says something, cut to 300 characters.
my $long_start = GPForum::Service::Realtime::ListenerSupervisor->new(
    ioloop   => GPForum::Test::RealtimeSupervisorIOLoop->new,
    listener => GPForum::Test::RealtimeDyingListener->new(
        die_start   => 1,
        start_error => "\n  "
          . ( 'x' x $LONG_ERROR_LENGTH )
          . "\nsecond line\n",
    ),
);
$long_start->start;
is(
    $long_start->snapshot->{last_error}{message},
    'x' x $ERROR_TEXT_LIMIT,
    'an error opening with a blank line keeps its first line, cut to 300'
);

done_testing();

1;
