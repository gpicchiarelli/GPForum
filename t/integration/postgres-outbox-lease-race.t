# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use JSON::MaybeXS qw(encode_json);
use Mojo::Log;
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Schema;
use GPForum::Service::Outbox::Dispatcher;
use GPForum::Infrastructure::Id;
use GPForum::Test::Id;
use GPForum::Test::InterposingOutboxTransport;
use GPForum::Test::OutboxClock;
use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

const my $NOW            => '2026-05-23T12:00:00Z';
const my $LEASE_END      => '2026-05-23T12:01:00Z';
const my $NEARLY_EXPIRED => '2026-05-23T12:00:50Z';
const my $RENEWED_END    => '2026-05-23T12:01:50Z';
const my $LATER          => '2026-05-23T12:01:30Z';
const my $LATER_END      => '2026-05-23T12:02:30Z';
const my $READY          => '2026-05-23T11:59:00Z';
const my $LAST_ATTEMPT   => 4;
const my $RIVAL_LIMIT    => 10;
const my $INSERT_SQL => join q{ },
  'INSERT INTO outbox_messages (outbox_id, event_id, queue, job_type,',
  'idempotency_key, payload, available_at, created_at, status,',
  'next_attempt_at, attempt_count, attempts)',
  q{VALUES (?, ?, 'domain', 'test.dispatch', ?, ?::jsonb, ?::timestamptz,},
  q{?::timestamptz + ? * interval '1 second', 'pending', ?::timestamptz,},
  '?, ?)';
const my $ROW_SQL =>
  'SELECT status, locked_by FROM outbox_messages WHERE outbox_id = ?';
const my $LETTERS_SQL =>
  'SELECT count(*) FROM dead_letters WHERE source_id = ?';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# A worker claims a batch for 60 seconds and works through it in order. Once
# the lease ran out a second worker could claim the rest of the batch and
# deliver it, and the first went on to deliver the same messages again; its
# failure path, finding a message that was no longer its own, recorded a dead
# letter for a message the second worker had delivered. Each case here runs
# the two workers on two connections to one database, the second acting
# while the first is in the middle of a dispatch.

_lost_lease_does_not_deliver_the_rest_of_the_batch();
_handled_messages_are_not_handed_to_a_rival();
_renewal_keeps_the_rest_of_the_batch();
_expired_lease_nobody_took_is_still_this_workers();
_lost_message_is_not_dead_lettered();
_cancellation_and_dead_letter_are_one_transaction();

done_testing();

# The rival claims both messages while the first is still with the slow
# worker, and delivers them. The first worker's own delivery of the message in
# hand is the duplicate at-least-once allows; the second message it no longer
# owns, and does not deliver.
sub _lost_lease_does_not_deliver_the_rest_of_the_batch {
    my $ctx = _context();
    _insert( $ctx, 'slow-1' );
    _insert( $ctx, 'slow-2' );

    my $rival = GPForum::Test::InterposingOutboxTransport->new;
    my $slow  = GPForum::Test::InterposingOutboxTransport->new(
        before => {
            $ctx->{id}{'slow-1'} => sub {
                _rival( $ctx, $rival )->dispatch_pending($RIVAL_LIMIT);
            },
        },
    );
    my $summary = _worker( $ctx, $slow )->dispatch_pending(2);

    is_deeply(
        _delivered( $ctx, $rival ),
        [ 'slow-1', 'slow-2' ],
        'the rival claims the expired batch and delivers it'
    );
    is_deeply( _delivered( $ctx, $slow ),
        ['slow-1'], 'the slow worker delivers only the message it was holding' )
      or diag( 'the slow worker delivered: ' . join q{, },
        @{ _delivered( $ctx, $slow ) } );
    is( $summary->{acknowledged},
        0, 'the slow worker acknowledges nothing it no longer owns' );
    is( $summary->{lost}, 2, 'and reports both claims as lost' );
    is( _row( $ctx, 'slow-2' )->{status},
        'done', 'the rival acknowledged the message' );
    like(
        $ctx->{log},
        qr/\Q$ctx->{id}{'slow-2'}: slow-worker lost its claim before\E/msx,
        'the lost claim is logged'
    );
    _finish($ctx);

    return;
}

# The lease runs out while the slow worker is on its last message. The two
# before it were acknowledged as soon as they were handled, so the rival finds
# only the message in hand -- not, as when the batch was acknowledged at its
# end, every message the slow worker had already delivered.
sub _handled_messages_are_not_handed_to_a_rival {
    my $ctx = _context();
    for my $name (qw(ack-1 ack-2 ack-3)) {
        _insert( $ctx, $name );
    }

    my %seen;
    my $rival     = GPForum::Test::InterposingOutboxTransport->new;
    my $transport = GPForum::Test::InterposingOutboxTransport->new(
        before => {
            $ctx->{id}{'ack-3'} => sub {
                %seen = map { $_ => _row( $ctx, $_, $ctx->{rival} )->{status} }
                  qw(ack-1 ack-2);
                _rival( $ctx, $rival )->dispatch_pending($RIVAL_LIMIT);
            },
        },
    );
    my $summary =
      _worker( $ctx, $transport )
      ->dispatch_pending( scalar keys %{ $ctx->{id} } );

    is_deeply(
        \%seen,
        { 'ack-1' => 'done', 'ack-2' => 'done' },
        'each message is acknowledged before the next is dispatched'
    );
    is_deeply( _delivered( $ctx, $rival ),
        ['ack-3'], 'the rival delivers only the message in hand' );
    is_deeply( _delivered( $ctx, $transport ),
        [qw(ack-1 ack-2 ack-3)],
        'which the slow worker delivered too, as at-least-once allows' );
    is( $summary->{acknowledged}, 2, 'the slow worker acknowledges two' );
    is( $summary->{lost},         1, 'and reports the third as lost' );
    _finish($ctx);

    return;
}

# The worker renews a message's claim before dispatching it, so a slow batch
# does not hand its tail to a rival worker.
sub _renewal_keeps_the_rest_of_the_batch {
    my $ctx = _context();
    _insert( $ctx, 'renew-1' );
    _insert( $ctx, 'renew-2' );

    my $clock = GPForum::Test::OutboxClock->new(
        now    => $NOW,
        future => $LEASE_END,
    );
    my $rival     = GPForum::Test::InterposingOutboxTransport->new;
    my $transport = GPForum::Test::InterposingOutboxTransport->new(
        before => {
            $ctx->{id}{'renew-1'} => sub {
                $clock->now($NEARLY_EXPIRED);
                $clock->future($RENEWED_END);
            },
            $ctx->{id}{'renew-2'} => sub {
                _rival( $ctx, $rival )->dispatch_pending($RIVAL_LIMIT);
            },
        },
    );
    my $summary =
      _worker( $ctx, $transport, clock => $clock )->dispatch_pending(2);

    is_deeply( _delivered( $ctx, $rival ),
        [], 'the rival finds the renewed claim still held' );
    is_deeply(
        _delivered( $ctx, $transport ),
        [ 'renew-1', 'renew-2' ],
        'the worker delivers its whole batch'
    );
    is( $summary->{acknowledged}, 2, 'and acknowledges it' );
    _finish($ctx);

    return;
}

# A lease that ran out while nobody took it is still this worker's: the
# renewal and the acknowledgement go by locked_by, not by the clock, so the
# message is acknowledged rather than left to be delivered a second time.
sub _expired_lease_nobody_took_is_still_this_workers {
    my $ctx = _context();
    _insert( $ctx, 'late-1' );
    _insert( $ctx, 'late-2' );

    my $clock = GPForum::Test::OutboxClock->new(
        now    => $NOW,
        future => $LEASE_END,
    );
    my $transport = GPForum::Test::InterposingOutboxTransport->new(
        before => {
            $ctx->{id}{'late-1'} => sub {
                $clock->now($LATER);
                $clock->future($LATER_END);
            },
        },
    );
    my $summary =
      _worker( $ctx, $transport, clock => $clock )->dispatch_pending(2);

    is( $summary->{acknowledged},         2, 'both messages are acknowledged' );
    is( $summary->{lost},                 0, 'none is lost' );
    is( _row( $ctx, 'late-2' )->{status}, 'done', 'the late one is done' );
    _finish($ctx);

    return;
}

# The message fails on its last attempt after the rival delivered it. The
# failure is no longer this worker's to record: no dead letter, the row stays
# done.
sub _lost_message_is_not_dead_lettered {
    my $ctx = _context();
    _insert( $ctx, 'doomed', $LAST_ATTEMPT );

    my $rival     = GPForum::Test::InterposingOutboxTransport->new;
    my $transport = GPForum::Test::InterposingOutboxTransport->new(
        before => {
            $ctx->{id}{doomed} => sub {
                _rival( $ctx, $rival )->dispatch_pending($RIVAL_LIMIT);
            },
        },
        fail_ids => { $ctx->{id}{doomed} => 'transient' },
    );
    my $summary = _worker( $ctx, $transport )->dispatch_pending(1);

    is_deeply( _delivered( $ctx, $rival ), ['doomed'],
        'the rival delivers it' );
    is( _value( $ctx, $LETTERS_SQL, $ctx->{id}{doomed} ),
        0, 'the worker that lost the message records no dead letter' );
    is( $summary->{dead_lettered}, 0, 'and reports none' );
    is( $summary->{lost},          1, 'but a lost claim' );
    is_deeply(
        _row( $ctx, 'doomed' ),
        { locked_by => undef, status => 'done' },
        'the rival acknowledgement stands'
    );
    like(
        $ctx->{log},
qr/\Q$ctx->{id}{doomed}: slow-worker lost its claim after it failed\E/msx,
        'the lost claim is logged'
    );
    _finish($ctx);

    return;
}

# The worker that owns the message writes its cancellation and its dead
# letter in one transaction: when the dead letter cannot be written -- here an
# id PostgreSQL refuses as a uuid -- the cancellation goes with it, and the
# message is still this worker's claim, to be retried once the lease ends.
sub _cancellation_and_dead_letter_are_one_transaction {
    my $ctx = _context();
    _insert( $ctx, 'unlettered', $LAST_ATTEMPT );

    my $transport = GPForum::Test::InterposingOutboxTransport->new(
        fail_ids => { $ctx->{id}{unlettered} => 'transient' } );
    my $worker =
      _worker( $ctx, $transport, id_service => GPForum::Test::Id->new );

    dies_ok( sub { $worker->dispatch_pending(1) },
        'a dead letter PostgreSQL refuses fails the dispatch' );
    is_deeply(
        _row( $ctx, 'unlettered' ),
        { locked_by => 'slow-worker', status => 'running' },
        'and takes the cancellation back with it'
    );
    is( _value( $ctx, $LETTERS_SQL, $ctx->{id}{unlettered} ),
        0, 'no dead letter is left' );
    _finish($ctx);

    return;
}

sub _context {
    my $database = GPForum::Test::PgDatabase->fresh;
    my $ctx      = {
        database => $database,
        id       => {},
        ids      => GPForum::Infrastructure::Id->new,
        log      => q{},
        rival    => _connect($database),
        schema   => $database->schema,
    };
    $ctx->{logger} = Mojo::Log->new( level => 'debug' );
    $ctx->{logger}->unsubscribe('message')->on(
        message => sub {
            my ( undef, $level, @lines ) = @_;
            $ctx->{log} .= join( q{ }, $level, @lines ) . "\n";
        }
    );

    return $ctx;
}

# The rival's connection goes before the database does.
sub _finish {
    my ($ctx) = @_;

    $ctx->{rival}->storage->disconnect;

    return;
}

# The slow worker: claims at noon for a minute, unless given its own clock.
sub _worker {
    my ( $ctx, $transport, %options ) = @_;

    return GPForum::Service::Outbox::Dispatcher->new(
        clock => GPForum::Test::OutboxClock->new(
            now    => $NOW,
            future => $LEASE_END,
        ),
        id_service => GPForum::Infrastructure::Id->new,
        logger     => $ctx->{logger},
        schema     => $ctx->{schema},
        transport  => $transport,
        worker_id  => 'slow-worker',
        %options,
    );
}

# The rival: on its own connection, ninety seconds later, when the slow
# worker's first lease has run out.
sub _rival {
    my ( $ctx, $transport ) = @_;

    return GPForum::Service::Outbox::Dispatcher->new(
        clock => GPForum::Test::OutboxClock->new(
            now    => $LATER,
            future => $LATER_END,
        ),
        id_service => GPForum::Infrastructure::Id->new,
        schema     => $ctx->{rival},
        transport  => $transport,
        worker_id  => 'rival-worker',
    );
}

# A ready message, known to the test by $name, created a second after the
# one inserted before it so that the claim takes them in that order.
sub _insert {
    my ( $ctx, $name, $attempts ) = @_;

    my $outbox_id = $ctx->{ids}->uuid;
    my $position  = keys %{ $ctx->{id} };
    $ctx->{id}{$name} = $outbox_id;
    $ctx->{schema}->storage->dbh->do(
        $INSERT_SQL,    undef,
        $outbox_id,     $ctx->{ids}->uuid,
        "key-$name",    encode_json( { name => $name } ),
        $READY,         $READY,
        $position,      $READY,
        $attempts // 0, $attempts // 0
    );

    return;
}

sub _row {
    my ( $ctx, $name, $schema ) = @_;

    return ( $schema // $ctx->{schema} )
      ->storage->dbh->selectrow_hashref( $ROW_SQL, undef, $ctx->{id}{$name} );
}

# The names of the messages a transport delivered, in order.
sub _delivered {
    my ( $ctx, $transport ) = @_;

    my %name = reverse %{ $ctx->{id} };

    return [ map { $name{$_} // $_ } @{ $transport->delivered } ];
}

sub _value {
    my ( $ctx, $sql, @bind ) = @_;

    my ($value) =
      $ctx->{schema}->storage->dbh->selectrow_array( $sql, undef, @bind );

    return $value;
}

sub _connect {
    my ($database) = @_;

    local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;

    return GPForum::Schema->connect_from_config(
        GPForum::Config->from_environment );
}

1;
