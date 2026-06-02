package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::CommandIdempotency;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::Schema;

our $VERSION = '0.001';

my $schema  = GPForum::Test::Schema->new;
my $service = GPForum::Service::Operations::CommandIdempotency->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => $schema,
);

my $calls = 0;
my $first = $service->run(
    _command_request( body_hash => 'hash-1' ),
    sub {
        $calls++;
        return {
            ok     => 1,
            status => 'ok',
            stored => { post => { post_id => 'post-1' } },
        };
    },
    sub {
        my ($result) = @_;

        return {
            ok      => $result->{ok},
            post_id => $result->{stored}{post}{post_id},
            status  => $result->{status},
        };
    }
);

ok( $first->{recorded}, 'first command execution is recorded' );
is( $calls, 1, 'first command executes callback' );
is( scalar @{ $schema->created_for('CommandLog') },
    1, 'command log row is created' );
is( $schema->command_logs->[0]{idempotency_key},
    'reply-command-1', 'command id is stored as the unique idempotency key' );
is( $schema->command_logs->[0]{status},
    'handled', 'successful command is marked handled' );
is( $schema->command_logs->[0]{payload}{response}{post_id},
    'post-1', 'command response envelope is stored' );
ok(
    $schema->command_logs->[0]{response_hash},
    'command response hash is stored'
);

my $replay = $service->run(
    _command_request( body_hash => 'hash-1' ),
    sub {
        $calls++;
        return { ok => 1, status => 'ok' };
    },
    sub { return { ok => 1, status => 'ok' }; }
);

ok( $replay->{replayed}, 'same command key replays stored response' );
is( $calls, 1, 'replayed command does not execute callback again' );
is( $replay->{response}{post_id},
    'post-1', 'replayed response returns original target id' );

my $conflict = $service->run(
    _command_request( body_hash => 'hash-2' ),
    sub {
        $calls++;
        return { ok => 1, status => 'ok' };
    },
    sub { return { ok => 1, status => 'ok' }; }
);

ok( $conflict->{conflict},
    'same command key with different payload is rejected' );
is( $calls, 1, 'conflicting command does not execute callback' );

my $missing_key_calls = 0;
my $missing_key       = $service->run(
    {
        actor_id     => 'user-1',
        command_type => 'reply.create',
        request      => { thread_id => 'thread-1' },
    },
    sub {
        $missing_key_calls++;
        return { ok => 1, status => 'ok' };
    },
    sub { return { ok => 1, status => 'ok' }; },
);
ok( $missing_key->{invalid}, 'missing command id is rejected' );
is(
    $missing_key->{error},
    'command_id is required',
    'missing command id reports stable error'
);
is( $missing_key_calls, 0, 'missing command id does not execute callback' );

my $pending = GPForum::Test::Schema->new;
push @{ $pending->command_logs },
  {
    command_id      => 'command-1',
    idempotency_key => 'pending-key',
    payload         => {
        request_hash => $schema->command_logs->[0]{payload}{request_hash},
    },
    status => 'accepted',
  };

my $pending_service = GPForum::Service::Operations::CommandIdempotency->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => $pending,
);
my $in_progress = $pending_service->run(
    {
        actor_id     => 'user-1',
        command_id   => 'pending-key',
        command_type => 'reply.create',
        request      => {
            body_hash => 'hash-1',
            thread_id => 'thread-1',
        },
    },
    sub { return { ok => 1, status => 'ok' }; },
    sub { return { ok => 1, status => 'ok' }; },
);

ok( $in_progress->{in_progress},
    'accepted command without response is treated as in progress' );

done_testing();

sub _command_request {
    my (%override) = @_;

    return {
        actor_id     => 'user-1',
        command_id   => 'reply-command-1',
        command_type => 'reply.create',
        request      => {
            body_hash => $override{body_hash},
            thread_id => 'thread-1',
        },
    };
}

1;
