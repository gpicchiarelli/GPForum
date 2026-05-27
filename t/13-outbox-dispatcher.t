package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Outbox::Dispatcher;
use GPForum::Test::OutboxClock;
use GPForum::Test::OutboxCreateResultSet;
use GPForum::Test::OutboxResultSet;
use GPForum::Test::OutboxRow;
use GPForum::Test::OutboxSchema;
use GPForum::Test::OutboxTransport;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 28;

plan tests => $EXPECTED_TESTS;

my $successful = GPForum::Test::OutboxRow->new(
    data => {
        outbox_id     => 'outbox-1',
        attempt_count => 0,
    }
);
my $failing = GPForum::Test::OutboxRow->new(
    data => {
        outbox_id     => 'outbox-2',
        attempt_count => 1,
        payload       => { event_id => 'event-2' },
    }
);

my $resultset =
  GPForum::Test::OutboxResultSet->new( rows => [ $successful, $failing ], );
my $dead_letters = GPForum::Test::OutboxCreateResultSet->new;
my $schema       = GPForum::Test::OutboxSchema->new(
    outbox_resultset      => $resultset,
    dead_letter_resultset => $dead_letters,
);
my $transport =
  GPForum::Test::OutboxTransport->new( fail_ids => { 'outbox-2' => 1 }, );
my $dispatcher = GPForum::Service::Outbox::Dispatcher->new(
    schema       => $schema,
    transport    => $transport,
    clock        => GPForum::Test::OutboxClock->new,
    worker_id    => 'worker-1',
    max_attempts => 2,
);

my $summary = $dispatcher->dispatch_pending(2);

is( $summary->{selected},      2, 'dispatcher selects ready messages' );
is( $summary->{dispatched},    1, 'dispatcher counts delivered messages' );
is( $summary->{failed},        0, 'dispatcher counts retryable failures' );
is( $summary->{dead_lettered}, 1, 'dispatcher counts exhausted failures' );
is_deeply(
    $resultset->last_query->{status}{-in},
    [ 'pending', 'failed' ],
    'dispatcher searches pending and failed statuses'
);
is( $resultset->last_query->{next_attempt_at}{'<='},
    '2026-05-23T12:00:00Z', 'dispatcher filters by retry schedule' );
is( $resultset->last_attrs->{rows}, 2, 'dispatcher applies caller limit' );
is( $successful->updates->[0]{status},
    'running', 'successful message is claimed first' );
is( $successful->updates->[0]{locked_by},
    'worker-1', 'successful message records worker lock' );
is( $successful->updates->[0]{locked_until},
    '2026-05-23T12:01:00Z', 'successful message records lock timeout' );
is( $successful->updates->[1]{status},
    'done', 'successful message is marked done' );
ok(
    !defined $successful->updates->[1]{locked_by},
    'successful message releases worker lock'
);
is_deeply( $transport->delivered, ['outbox-1'],
    'transport receives only successful message' );
is( $failing->updates->[0]{status},
    'running', 'failing message is claimed first' );
is( $failing->updates->[1]{status},
    'cancelled', 'exhausted message is cancelled' );
is( $failing->updates->[1]{attempt_count},
    2, 'failing message increments attempt count' );
is( $failing->updates->[1]{attempts},
    2, 'failing message keeps legacy attempts in sync' );
is( $failing->updates->[1]{last_error},
    'boom', 'failing message records error text' );
is(
    $failing->updates->[1]{last_error_class},
    'GPForum::Test::OutboxFailure',
    'failing message records error class'
);
is( $failing->updates->[1]{next_attempt_at},
    '2026-05-23T12:01:00Z', 'failing message schedules retry' );
ok(
    !defined $failing->updates->[1]{locked_by},
    'failing message releases worker lock'
);
is( $successful->get_column('status'),
    'done', 'successful row data reflects final status' );
is( $failing->get_column('status'),
    'cancelled', 'failing row data reflects final status' );
is( scalar @{ $dead_letters->created }, 1, 'dead letter row is created' );
is( $dead_letters->created->[0]{source_table},
    'outbox_messages', 'dead letter stores source table' );
is( $dead_letters->created->[0]{source_id},
    'outbox-2', 'dead letter stores source id' );
is( $dead_letters->created->[0]{retry_count},
    2, 'dead letter stores retry count' );
is_deeply(
    $dead_letters->created->[0]{payload},
    { event_id => 'event-2' },
    'dead letter stores failed payload'
);

1;
