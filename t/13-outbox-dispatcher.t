package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Outbox::DeadLetterRecorder;
use GPForum::Service::Outbox::Dispatcher;
use GPForum::Test::Id;
use GPForum::Test::OutboxClock;
use GPForum::Test::OutboxCreateResultSet;
use GPForum::Test::OutboxDbh;
use GPForum::Test::OutboxResultSet;
use GPForum::Test::OutboxRow;
use GPForum::Test::OutboxSchema;
use GPForum::Test::OutboxStorage;
use GPForum::Test::OutboxTransport;

our $VERSION = '0.001';

const my $LIMIT_BIND_INDEX  => 6;
const my $WORKER_BIND_INDEX => 9;
const my $DEFAULT_MAX       => 5;

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
    id_service   => GPForum::Test::Id->new,
    worker_id    => 'worker-1',
    max_attempts => 2,
);

my $summary = $dispatcher->dispatch_pending(2);

is( $summary->{selected},      2, 'dispatcher selects ready messages' );
is( $summary->{dispatched},    1, 'dispatcher counts delivered messages' );
is( $summary->{failed},        0, 'dispatcher counts retryable failures' );
is( $summary->{dead_lettered}, 1, 'dispatcher counts exhausted failures' );
is_deeply(
    $resultset->last_query->[0]{status}{-in},
    [ 'pending', 'failed' ],
    'dispatcher claims pending and failed statuses'
);
is( $resultset->last_query->[0]{next_attempt_at}{'<='},
    '2026-05-23T12:00:00Z', 'dispatcher claims by retry schedule' );
is( $resultset->last_query->[1]{status},
    'running', 'dispatcher claim includes running messages' );
is( $resultset->last_query->[1]{locked_until}{'<='},
    '2026-05-23T12:00:00Z', 'dispatcher claim recovers stale locks' );
is( $resultset->last_attrs->{rows}, 2, 'dispatcher applies caller limit' );
is_deeply(
    $resultset->last_attrs->{order_by},
    [
        { -asc => 'next_attempt_at' },
        { -asc => 'created_at' },
        { -asc => 'outbox_id' },
    ],
    'dispatcher claims oldest ready messages first'
);
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
is( $failing->updates->[1]{failure_type},
    'transient', 'failing message records classified failure type' );
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
is( $dead_letters->created->[0]{failure_type},
    'transient', 'dead letter stores classified failure type' );
is_deeply(
    $dead_letters->created->[0]{payload},
    { event_id => 'event-2' },
    'dead letter stores failed payload'
);

my $letter_failure = {
    attempt_count => 2,
    error_class   => 'transport',
    error_message => 'failed',
    failure_type  => 'transient',
};
my $same_letter =
  $dispatcher->dead_letter_recorder->create_dead_letter( $failing,
    $letter_failure );
ok( $same_letter->{skipped}, 'already-recorded dead letter is skipped' );
is( scalar @{ $dead_letters->created },
    1, 'already-recorded dead letter does not insert another row' );
$dead_letters->find_misses(1);
my $raced_letter =
  $dispatcher->dead_letter_recorder->create_dead_letter( $failing,
    $letter_failure );
ok( $raced_letter->{skipped}, 'unique dead-letter race reuses the source row' );
is( scalar @{ $dead_letters->created },
    1, 'unique dead-letter race does not insert another row' );

my $letter_pk_rows = GPForum::Test::OutboxCreateResultSet->new;
$letter_pk_rows->create(
    {
        dead_letter_id => 'generated-1',
        source_id      => 'other-outbox',
        source_table   => 'outbox_messages',
    }
);
my $letter_pk_recorder = GPForum::Service::Outbox::DeadLetterRecorder->new(
    clock      => GPForum::Test::OutboxClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::OutboxSchema->new(
        dead_letter_resultset => $letter_pk_rows,
    ),
);
my $letter_pk_message = GPForum::Test::OutboxRow->new(
    data => {
        outbox_id => 'outbox-pk',
        payload   => { event_id => 'event-pk' },
    }
);
my $letter_pk = $letter_pk_recorder->create_dead_letter( $letter_pk_message,
    $letter_failure );
ok( !$letter_pk->{skipped},
    'unique dead-letter id collision remints and records' );
is( $letter_pk->{dead_letter_id},
    'generated-2', 'unique dead-letter id collision remints the id' );
is( $letter_pk->{source_id},
    'outbox-pk', 'unique dead-letter id collision keeps this source' );
is( scalar @{ $letter_pk_rows->created },
    2, 'unique dead-letter id collision inserts this review row' );

my $letter_leftover_rows = GPForum::Test::OutboxCreateResultSet->new;
$letter_leftover_rows->create(
    {
        dead_letter_id => 'generated-1',
        source_id      => 'outbox-leftover',
        source_table   => 'outbox_messages',
    }
);
$letter_leftover_rows->find_misses(1);
my $letter_leftover_recorder =
  GPForum::Service::Outbox::DeadLetterRecorder->new(
    clock      => GPForum::Test::OutboxClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::OutboxSchema->new(
        dead_letter_resultset => $letter_leftover_rows,
    ),
  );
my $letter_leftover_message = GPForum::Test::OutboxRow->new(
    data => {
        outbox_id => 'outbox-leftover',
        payload   => { event_id => 'event-leftover' },
    }
);
my $letter_leftover =
  $letter_leftover_recorder->create_dead_letter( $letter_leftover_message,
    $letter_failure );
ok( $letter_leftover->{skipped},
    'leftover dead-letter id race reuses this review row' );
is( $letter_leftover->{dead_letter_id},
    'generated-1', 'leftover dead-letter id race keeps this review row' );
is( $letter_leftover->{source_id},
    'outbox-leftover', 'leftover dead-letter id race keeps this source' );
is( scalar @{ $letter_leftover_rows->created },
    1, 'leftover dead-letter id race does not insert a second review row' );

my $replay = $dispatcher->dispatch_pending(2);
is( $replay->{selected}, 0,
    'cancelled dead-lettered row is not claimed again' );
is( $replay->{dead_lettered}, 0, 'cancelled row is not dead-lettered twice' );
is( scalar @{ $dead_letters->created },
    1, 'dead letter remains a single review row' );

my $permanent = GPForum::Test::OutboxRow->new(
    data => {
        attempt_count => 0,
        outbox_id     => 'outbox-permanent',
        payload       => { event_id => 'event-permanent' },
    }
);
my $permanent_letters = GPForum::Test::OutboxCreateResultSet->new;
my $permanent_schema  = GPForum::Test::OutboxSchema->new(
    dead_letter_resultset => $permanent_letters,
    outbox_resultset      =>
      GPForum::Test::OutboxResultSet->new( rows => [$permanent] ),
);
my $permanent_transport = GPForum::Test::OutboxTransport->new(
    fail_ids   => { 'outbox-permanent' => 1 },
    fail_types => { 'outbox-permanent' => 'permanent' },
);
my $permanent_dispatcher = GPForum::Service::Outbox::Dispatcher->new(
    clock        => GPForum::Test::OutboxClock->new,
    id_service   => GPForum::Test::Id->new,
    max_attempts => $DEFAULT_MAX,
    schema       => $permanent_schema,
    transport    => $permanent_transport,
    worker_id    => 'worker-permanent',
);
my $permanent_summary = $permanent_dispatcher->dispatch_pending(1);
is( $permanent_summary->{dead_lettered},
    1, 'permanent failure is dead-lettered on the first attempt' );
is( $permanent_summary->{failed},
    0, 'permanent failure is not scheduled for retry' );
is( $permanent->get_column('status'),
    'cancelled', 'permanent failure cancels the outbox row' );
is( $permanent_letters->created->[0]{failure_type},
    'permanent', 'permanent dead letter stores the classified failure type' );
is( $permanent_dispatcher->dispatch_pending(1)->{selected},
    0, 'permanent dead-lettered row is not claimed again' );

my $pg_row = GPForum::Test::OutboxRow->new(
    data => {
        outbox_id       => 'pg-1',
        status          => 'running',
        locked_by       => 'pg-worker',
        next_attempt_at => '2026-05-23T12:00:00Z',
        created_at      => '2026-05-23T12:00:00Z',
    }
);
my $pg_resultset = GPForum::Test::OutboxResultSet->new( rows => [$pg_row] );
my $pg_dbh       = GPForum::Test::OutboxDbh->new( claimed_ids => ['pg-1'] );
my $pg_schema    = GPForum::Test::OutboxSchema->new(
    outbox_resultset      => $pg_resultset,
    dead_letter_resultset => GPForum::Test::OutboxCreateResultSet->new,
    storage => GPForum::Test::OutboxStorage->new( dbh => $pg_dbh ),
);
my $pg_dispatcher = GPForum::Service::Outbox::Dispatcher->new(
    schema    => $pg_schema,
    transport => GPForum::Test::OutboxTransport->new,
    clock     => GPForum::Test::OutboxClock->new,
    worker_id => 'pg-worker',
);
my @pg_claimed = $pg_dispatcher->claim_ready_batch(1);

is( scalar @pg_claimed,
    1, 'PostgreSQL claim returns rows already locked by current worker' );
is(
    ref $pg_claimed[0],
    'GPForum::Service::Outbox::ClaimedMessage',
    'PostgreSQL claim returns lightweight DBI-backed messages'
);
is_deeply( $pg_resultset->last_query, {},
    'PostgreSQL claim does not reload claimed rows through DBIx::Class' );
like(
    $pg_dbh->sql,
    qr/FOR [ ] UPDATE [ ] SKIP [ ] LOCKED/msx,
    'PostgreSQL claim uses FOR UPDATE SKIP LOCKED'
);
my $stable_claim_order =
  'ORDER BY next_attempt_at ASC, created_at ASC, outbox_id ASC';
ok(
    index( $pg_dbh->sql, $stable_claim_order ) >= 0,
    'PostgreSQL claim uses stable ready-queue ordering'
);
like(
    $pg_dbh->sql,
    qr/UPDATE [ ] outbox_messages/msx,
    'PostgreSQL claim updates the selected rows atomically'
);
like(
    $pg_dbh->sql,
    qr/RETURNING [ ] outbox[.][*]/msx,
    'PostgreSQL claim returns the updated rows'
);
is( $pg_dbh->bind->[$LIMIT_BIND_INDEX],
    1, 'PostgreSQL claim binds caller limit' );
is( $pg_dbh->bind->[$WORKER_BIND_INDEX],
    'pg-worker', 'PostgreSQL claim binds current worker id' );

my $pg_done_dbh = GPForum::Test::OutboxDbh->new(
    claimed_rows => [
        {
            outbox_id       => 'pg-done-1',
            status          => 'running',
            locked_by       => 'pg-worker',
            attempt_count   => 0,
            payload         => { event_id => 'event-pg-done-1' },
            next_attempt_at => '2026-05-23T12:00:00Z',
            created_at      => '2026-05-23T12:00:00Z',
        },
        {
            outbox_id       => 'pg-done-2',
            status          => 'running',
            locked_by       => 'pg-worker',
            attempt_count   => 0,
            payload         => { event_id => 'event-pg-done-2' },
            next_attempt_at => '2026-05-23T12:00:00Z',
            created_at      => '2026-05-23T12:00:00Z',
        },
    ],
);
my $pg_done_schema = GPForum::Test::OutboxSchema->new(
    outbox_resultset      => GPForum::Test::OutboxResultSet->new,
    dead_letter_resultset => GPForum::Test::OutboxCreateResultSet->new,
    storage => GPForum::Test::OutboxStorage->new( dbh => $pg_done_dbh ),
);
my $pg_done_transport = GPForum::Test::OutboxTransport->new;
my $pg_done_summary   = GPForum::Service::Outbox::Dispatcher->new(
    schema    => $pg_done_schema,
    transport => $pg_done_transport,
    clock     => GPForum::Test::OutboxClock->new,
    worker_id => 'pg-worker',
)->dispatch_pending(2);

is( $pg_done_summary->{dispatched},
    2, 'PostgreSQL direct dispatcher dispatches claimed messages' );
is( $pg_done_summary->{acknowledged},
    2, 'PostgreSQL direct dispatcher batch-acknowledges done messages' );
is_deeply(
    $pg_done_transport->delivered,
    [ 'pg-done-1', 'pg-done-2' ],
    'PostgreSQL direct dispatcher preserves delivery order'
);
is( scalar @{ $pg_done_dbh->do_sql },
    1, 'PostgreSQL direct dispatcher uses one batch ack statement' );
like(
    $pg_done_dbh->do_sql->[0],
    qr/WHERE [ ] outbox_id [ ] IN [ ] [(][?],[?][)]/msx,
    'PostgreSQL batch ack targets the claimed ids together'
);

done_testing();

1;
