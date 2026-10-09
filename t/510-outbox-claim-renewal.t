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
use GPForum::Test::InterposingOutboxTransport;
use GPForum::Test::OutboxClock;
use GPForum::Test::OutboxCreateResultSet;
use GPForum::Test::OutboxDbh;
use GPForum::Test::OutboxResultSet;
use GPForum::Test::OutboxSchema;
use GPForum::Test::OutboxStorage;

our $VERSION = '0.001';

const my $WORKER    => 'slow-worker';
const my $LEASE_END => '2026-05-23T12:01:00Z';
const my $READY     => '2026-05-23T12:00:00Z';

# A worker claims a batch for Retry's lock_seconds and works through it in
# order. It used to acknowledge the batch at its end and never renew the
# claim, so a batch slower than the lease handed its tail to a second worker:
# the messages not yet dispatched were delivered by both, and those already
# delivered but not yet acknowledged were delivered again. Each message's
# claim is now renewed before it is dispatched and its acknowledgement written
# right after, both only while the message is still this worker's. The
# PostgreSQL race itself is t/integration/postgres-outbox-lease-race.t; these
# are the same rules on the doubles.

_renews_before_and_acknowledges_after_each_dispatch();
_message_taken_before_its_turn_is_not_dispatched();
_message_taken_during_its_dispatch_is_not_acknowledged();
_lost_claim_without_a_logger_is_still_counted();

done_testing();

sub _renews_before_and_acknowledges_after_each_dispatch {
    my $ctx = _context(qw(m1 m2 m3));

    my %writes_before;
    for my $id (qw(m1 m2 m3)) {
        $ctx->{transport}->before->{$id} =
          sub { $writes_before{$id} = $ctx->{dbh}->writes($WORKER) };
    }
    my $summary = _dispatch_batch($ctx);

    is_deeply(
        \%writes_before,
        {
            m1 => [qw(renew:m1)],
            m2 => [qw(renew:m1 done:m1 renew:m2)],
            m3 => [qw(renew:m1 done:m1 renew:m2 done:m2 renew:m3)],
        },
        'each claim is renewed before its dispatch and acknowledged after it'
    );
    is_deeply(
        $ctx->{dbh}->writes($WORKER),
        [qw(renew:m1 done:m1 renew:m2 done:m2 renew:m3 done:m3)],
        'the last message is acknowledged as soon as it is handled'
    );
    is( $ctx->{dbh}->do_bind->[0][0],
        $LEASE_END, 'a renewal runs the lease a whole lock_seconds from now' );
    is(
        _counts($summary),
'selected=3 dispatched=3 acknowledged=3 failed=0 dead_lettered=0 lost=0',
        'the summary counts every message dispatched and acknowledged'
    );

    return;
}

# The lease ran out while m1 was being dispatched and another worker claimed
# m2. Its renewal finds it no longer this worker's, and it is skipped: the
# worker that holds it now delivers it.
sub _message_taken_before_its_turn_is_not_dispatched {
    my $ctx = _context(qw(m1 m2 m3));
    $ctx->{transport}->before( { m1 => sub { _taken( $ctx, 'm2' ) } } );

    my $summary = _dispatch_batch($ctx);

    is_deeply( $ctx->{transport}->delivered,
        [qw(m1 m3)], 'the message another worker claimed is not dispatched' );
    is_deeply(
        $ctx->{dbh}->writes($WORKER),
        [qw(renew:m1 done:m1 renew:m2 renew:m3 done:m3)],
        'and nothing is written for it after its renewal failed'
    );
    is(
        _counts($summary),
'selected=3 dispatched=2 acknowledged=2 failed=0 dead_lettered=0 lost=1',
        'it is counted as lost, not as dispatched'
    );
    is(
        $ctx->{log},
        "warn outbox message m2: $WORKER lost its claim"
          . " before dispatching it; skipped\n",
        'and logged as a warning'
    );

    return;
}

# The lease ran out during m1's own dispatch and another worker claimed it.
# That dispatch is the duplicate at-least-once allows; the acknowledgement
# finds the message no longer this worker's and writes nothing over the other
# worker's claim.
sub _message_taken_during_its_dispatch_is_not_acknowledged {
    my $ctx = _context(qw(m1 m2));
    $ctx->{transport}->before( { m1 => sub { _taken( $ctx, 'm1' ) } } );

    my $summary = _dispatch_batch($ctx);

    is_deeply( $ctx->{transport}->delivered,
        [qw(m1 m2)], 'the message in hand is delivered' );
    is(
        _counts($summary),
'selected=2 dispatched=2 acknowledged=1 failed=0 dead_lettered=0 lost=1',
        'but its acknowledgement does not land, and its claim is lost'
    );
    is(
        $ctx->{log},
        "warn outbox message m1: $WORKER lost its claim after dispatching it;"
          . " another worker may deliver it again\n",
        'which is logged'
    );

    return;
}

sub _lost_claim_without_a_logger_is_still_counted {
    my $ctx = _context(qw(m1 m2));
    $ctx->{transport}->before( { m1 => sub { _taken( $ctx, 'm2' ) } } );

    my $summary = _dispatch_batch( $ctx, logger => undef );

    is( $summary->{lost}, 1,
        'a dispatcher with no logger counts a lost claim' );

    return;
}

# A batch of ready messages claimed by this worker, every one of them still
# its own until _taken says otherwise.
sub _context {
    my (@ids) = @_;

    my $dbh = GPForum::Test::OutboxDbh->new(
        claimed_rows => [ map { _claimed_row($_) } @ids ],
        owned_ids    => [@ids],
    );
    my $ctx = {
        dbh       => $dbh,
        log       => q{},
        transport => GPForum::Test::InterposingOutboxTransport->new,
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

sub _dispatcher {
    my ( $ctx, %options ) = @_;

    return GPForum::Service::Outbox::Dispatcher->new(
        clock  => GPForum::Test::OutboxClock->new,
        logger => $ctx->{logger},
        schema => GPForum::Test::OutboxSchema->new(
            outbox_resultset      => GPForum::Test::OutboxResultSet->new,
            dead_letter_resultset => GPForum::Test::OutboxCreateResultSet->new,
            storage => GPForum::Test::OutboxStorage->new( dbh => $ctx->{dbh} ),
        ),
        transport => $ctx->{transport},
        worker_id => $WORKER,
        %options,
    );
}

# The whole batch the context claimed, dispatched in one call.
sub _dispatch_batch {
    my ( $ctx, %options ) = @_;

    return _dispatcher( $ctx, %options )
      ->dispatch_pending( scalar @{ $ctx->{dbh}->claimed_rows } );
}

sub _counts {
    my ($summary) = @_;

    return join q{ },
      map { $_ . q{=} . ( $summary->{$_} // 'none' ) }
      qw(selected dispatched acknowledged failed dead_lettered lost);
}

sub _claimed_row {
    my ($id) = @_;

    return {
        attempt_count   => 0,
        created_at      => $READY,
        locked_by       => $WORKER,
        next_attempt_at => $READY,
        outbox_id       => $id,
        payload         => { event_id => "event-$id" },
        status          => 'running',
    };
}

# Another worker claimed the message: this one's guarded writes no longer
# find it.
sub _taken {
    my ( $ctx, $id ) = @_;

    $ctx->{dbh}
      ->owned_ids( [ grep { $_ ne $id } @{ $ctx->{dbh}->owned_ids } ] );

    return;
}

1;
