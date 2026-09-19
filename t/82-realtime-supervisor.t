package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';

use GPForum::Service::Realtime::ListenerSupervisor;

our $VERSION = '0.001';

{

    package GPForum::Test::RealtimeSupervisorListener;

    sub new {
        my ( $class, %input ) = @_;

        return bless {
            fail_poll  => $input{fail_poll}  ? 1 : 0,
            fail_start => $input{fail_start} ? 1 : 0,
            polls      => 0,
            reconnects => 0,
            starts     => 0,
            stops      => 0,
        }, $class;
    }

    sub fail_poll {
        my ( $self, $value ) = @_;

        $self->{fail_poll} = $value ? 1 : 0 if @_ > 1;

        return $self->{fail_poll};
    }

    sub polls {
        my ($self) = @_;

        return $self->{polls};
    }

    sub reconnects {
        my ($self) = @_;

        return $self->{reconnects};
    }

    sub starts {
        my ($self) = @_;

        return $self->{starts};
    }

    sub stops {
        my ($self) = @_;

        return $self->{stops};
    }

    sub start {
        my ($self) = @_;

        $self->{starts} += 1;
        return { ok => 0, reason => 'listen_failed' } if $self->{fail_start};

        return { ok => 1 };
    }

    sub stop {
        my ($self) = @_;

        $self->{stops} += 1;

        return { ok => 1 };
    }

    sub poll_once {
        my ($self) = @_;

        $self->{polls} += 1;
        return { ok => 0, reason => 'poll_failed' } if $self->{fail_poll};

        return { ok => 1, delivered => 0 };
    }

    sub reconnect {
        my ($self) = @_;

        $self->{reconnects} += 1;
        return { ok => 1 };
    }

    sub snapshot {
        return { status => 'test' };
    }
}

{

    package GPForum::Test::RealtimeSupervisorIOLoop;

    sub new {
        my ($class) = @_;

        return bless {
            finish_callbacks => [],
            recurring_calls  => [],
            removed          => [],
            sequence         => 0,
            timer_calls      => [],
        }, $class;
    }

    sub recurring_calls {
        my ($self) = @_;

        return $self->{recurring_calls};
    }

    sub removed {
        my ($self) = @_;

        return $self->{removed};
    }

    sub timer_calls {
        my ($self) = @_;

        return $self->{timer_calls};
    }

    sub finish_callbacks {
        my ($self) = @_;

        return $self->{finish_callbacks};
    }

    sub on {
        my ( $self, $event, $callback ) = @_;

        push @{ $self->{finish_callbacks} }, $callback if $event eq 'finish';

        return $self;
    }

    sub recurring {
        my ( $self, $interval, $callback ) = @_;

        $self->{sequence} += 1;
        my $id = 'recurring-' . $self->{sequence};
        push @{ $self->{recurring_calls} },
          { id => $id, interval => $interval, callback => $callback };

        return $id;
    }

    sub timer {
        my ( $self, $interval, $callback ) = @_;

        $self->{sequence} += 1;
        my $id = 'timer-' . $self->{sequence};
        push @{ $self->{timer_calls} },
          { id => $id, interval => $interval, callback => $callback };

        return $id;
    }

    sub remove {
        my ( $self, $id ) = @_;

        push @{ $self->{removed} }, $id;

        return 1;
    }
}

my $ioloop     = GPForum::Test::RealtimeSupervisorIOLoop->new;
my $listener   = GPForum::Test::RealtimeSupervisorListener->new;
my $supervisor = GPForum::Service::Realtime::ListenerSupervisor->new(
    heartbeat_interval_seconds => 9,
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
    9, 'heartbeat interval is configurable' );

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

done_testing();
