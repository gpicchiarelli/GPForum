# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojo::Log;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Outbox::Dispatcher;
use GPForum::Test::Id;
use GPForum::Test::InterposingOutboxTransport;
use GPForum::Test::OutboxClock;
use GPForum::Test::OutboxCreateResultSet;
use GPForum::Test::OutboxDbh;
use GPForum::Test::OutboxResultSet;
use GPForum::Test::OutboxSchema;
use GPForum::Test::OutboxStorage;

our $VERSION = '0.001';

const my $WORKER       => 'slow-worker';
const my $READY        => '2026-05-23T12:00:00Z';
const my $LAST_ATTEMPT => 4;

# A message that fails is written back as failed, or as cancelled with a dead
# letter once its attempts run out. That write checked locked_by but nobody
# looked at how many rows it updated: a worker whose claim had expired and
# been taken by another, which might already have delivered the message,
# still recorded a dead letter for it. The failure is now written only while
# the message is still this worker's, and the dead letter only when that
# write updated the row, in the same transaction. A worker that lost the
# message logs it and moves on. The PostgreSQL race is in
# t/integration/postgres-outbox-lease-race.t.

_lost_last_attempt_records_no_dead_letter();
_lost_retryable_failure_records_nothing();
_owned_last_attempt_is_dead_lettered();

done_testing();

# Another worker claims the message while its last attempt is failing here.
sub _lost_last_attempt_records_no_dead_letter {
    my $ctx = _context( 'doomed', $LAST_ATTEMPT, taken => 1 );

    my $summary = _dispatcher($ctx)->dispatch_pending(1);

    is_deeply( $ctx->{dead_letters}->created,
        [], 'the worker that lost the message records no dead letter' );
    is_deeply(
        $ctx->{dbh}->writes($WORKER),
        [qw(renew:doomed cancelled:doomed)],
        'its cancellation was written only under the ownership guard'
    );
    is_deeply(
        [ @{$summary}{qw(dead_lettered failed lost)} ],
        [ 0, 0, 1 ],
        'it reports a lost claim, not a dead letter'
    );
    is(
        $ctx->{log},
        "warn outbox message doomed: $WORKER lost its claim after it failed;"
          . " the failure is left to the worker that owns it\n",
        'and logs it'
    );

    return;
}

sub _lost_retryable_failure_records_nothing {
    my $ctx = _context( 'flaky', 0, taken => 1 );

    my $summary = _dispatcher($ctx)->dispatch_pending(1);

    is_deeply(
        $ctx->{dbh}->writes($WORKER),
        [qw(renew:flaky failed:flaky)],
        'a retryable failure is written under the same guard'
    );
    is_deeply(
        [ @{$summary}{qw(failed lost)} ],
        [ 0, 1 ],
        'and, once the message is lost, counted as lost, not as a retry'
    );

    return;
}

# The worker that still owns the message cancels it and records its dead
# letter, both in one transaction.
sub _owned_last_attempt_is_dead_lettered {
    my $ctx          = _context( 'doomed', $LAST_ATTEMPT, taken => 0 );
    my $dispatcher   = _dispatcher($ctx);
    my $transactions = $dispatcher->schema->transaction_count;

    my $summary = $dispatcher->dispatch_pending(1);

    is( scalar @{ $ctx->{dead_letters}->created },
        1, 'the owner records the dead letter' );
    is( $ctx->{dead_letters}->created->[0]{source_id},
        'doomed', 'for the message' );
    is_deeply(
        $ctx->{dbh}->writes($WORKER),
        [qw(renew:doomed cancelled:doomed)],
        'after its guarded cancellation'
    );
    cmp_ok( $dispatcher->schema->transaction_count,
        q{>}, $transactions, 'in a transaction' );
    is_deeply(
        [ @{$summary}{qw(dead_lettered lost)} ],
        [ 1, 0 ],
        'and reports it'
    );
    is( $ctx->{log}, q{}, 'no claim was lost' );

    return;
}

# One claimed message on the doubles, failing transiently on its next
# attempt; taken => 1 has another worker claim it during that attempt.
sub _context {
    my ( $id, $attempts, %options ) = @_;

    my $dbh = GPForum::Test::OutboxDbh->new(
        claimed_rows => [
            {
                attempt_count   => $attempts,
                created_at      => $READY,
                locked_by       => $WORKER,
                next_attempt_at => $READY,
                outbox_id       => $id,
                payload         => { event_id => "event-$id" },
                status          => 'running',
            }
        ],
        owned_ids => [$id],
    );
    my $ctx = {
        dbh          => $dbh,
        dead_letters => GPForum::Test::OutboxCreateResultSet->new,
        log          => q{},
    };
    $ctx->{transport} = GPForum::Test::InterposingOutboxTransport->new(
        before => {
            $id => sub {
                if ( $options{taken} ) {
                    $dbh->owned_ids( [] );
                }
            },
        },
        fail_ids => { $id => 'transient' },
    );
    $ctx->{logger} = Mojo::Log->new( level => 'debug' );
    $ctx->{logger}->unsubscribe('message')->on(
        message => sub {
            my ( undef, $level, @lines ) = @_;
            $ctx->{log} .= join( q{ }, $level, @lines ) . "\n";
        }
    );

    return $ctx;
}

sub _dispatcher {
    my ($ctx) = @_;

    return GPForum::Service::Outbox::Dispatcher->new(
        clock      => GPForum::Test::OutboxClock->new,
        id_service => GPForum::Test::Id->new,
        logger     => $ctx->{logger},
        schema     => GPForum::Test::OutboxSchema->new(
            outbox_resultset      => GPForum::Test::OutboxResultSet->new,
            dead_letter_resultset => $ctx->{dead_letters},
            storage => GPForum::Test::OutboxStorage->new( dbh => $ctx->{dbh} ),
        ),
        transport => $ctx->{transport},
        worker_id => $WORKER,
    );
}

1;
