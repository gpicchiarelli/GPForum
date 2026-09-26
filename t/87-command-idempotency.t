# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

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

my $race_schema  = GPForum::Test::Schema->new;
my $race_calls   = 0;
my $race_service = GPForum::Service::Operations::CommandIdempotency->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => $race_schema,
);
my $race_first = $race_service->run(
    _command_request( body_hash => 'hash-1' ),
    sub {
        $race_calls++;
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
ok( $race_first->{recorded}, 'race fixture records the winning command' );

$race_schema->skip_search_count(1);
my $race_second = $race_service->run(
    _command_request( body_hash => 'hash-1' ),
    sub {
        $race_calls++;
        return { ok => 1, status => 'ok' };
    },
    sub { return { ok => 1, status => 'ok' }; }
);
ok( $race_second->{replayed},
    'concurrent unique insert is treated as idempotent replay' );
is( $race_calls, 1, 'losing unique insert does not run the callback' );
is( scalar @{ $race_schema->command_logs },
    1, 'concurrent unique insert keeps one command_log row' );
is( $race_second->{response}{post_id},
    'post-1', 'replay after unique conflict returns the original target' );

my $pending_race = GPForum::Test::Schema->new;
push @{ $pending_race->command_logs },
  {
    command_id      => 'command-1',
    idempotency_key => 'pending-key',
    payload         => {
        request_hash => $schema->command_logs->[0]{payload}{request_hash},
    },
    status => 'accepted',
  };
$pending_race->skip_search_count(1);
my $pending_race_service =
  GPForum::Service::Operations::CommandIdempotency->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => $pending_race,
  );
my $pending_race_result = $pending_race_service->run(
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
ok( $pending_race_result->{in_progress},
    'unique conflict on an unfinished command is in progress' );

my $id_schema = GPForum::Test::Schema->new(
    command_logs => [
        {
            command_id      => 'generated-1',
            idempotency_key => 'other-command',
            payload         => {
                request_hash => 'other-hash',
                response     => { post_id => 'other-post' },
            },
            status => 'handled',
        }
    ]
);
my $id_calls   = 0;
my $id_service = GPForum::Service::Operations::CommandIdempotency->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => $id_schema,
);
my $id_result = $id_service->run(
    _command_request( body_hash => 'hash-1' ),
    sub {
        $id_calls++;
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
ok( $id_result->{recorded}, 'unique command id collision remints and records' );
is( $id_calls, 1, 'unique command id collision still executes callback' );
is( $id_schema->created_for('CommandLog')->[0]{command_id},
    'generated-3', 'unique command id collision remints the id' );
is( $id_schema->created_for('CommandLog')->[0]{idempotency_key},
    'reply-command-1',
    'unique command id collision does not replay another command' );

my $leftover_schema = GPForum::Test::Schema->new;
$leftover_schema->resultset('CommandLog')->create(
    {
        command_id      => 'generated-1',
        idempotency_key => 'reply-command-1',
        payload         => { request_hash => 'pending-hash' },
        status          => 'accepted',
    }
);
$leftover_schema->skip_search_count(1);
my $leftover_calls   = 0;
my $leftover_service = GPForum::Service::Operations::CommandIdempotency->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => $leftover_schema,
);
my $leftover_result = $leftover_service->run(
    _command_request( body_hash => 'hash-1' ),
    sub {
        $leftover_calls++;
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
ok( $leftover_result->{recorded},
    'leftover command id race finishes this command' );
is( $leftover_calls, 1, 'leftover command id race still executes callback' );
is( $leftover_schema->created_for('CommandLog')->[0]{command_id},
    'generated-1', 'leftover command id race keeps this command' );
is( scalar @{ $leftover_schema->created_for('CommandLog') },
    1, 'leftover command id race does not insert a second command' );

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
