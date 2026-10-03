# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Notification::Dispatcher;
use GPForum::Test::AuditChainSchema;
use GPForum::Test::AuditLookupSchema;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::NotificationResultSet;
use GPForum::Test::NotificationTxnSchema;
use GPForum::Test::PermissionEngine;

our $VERSION = '0.001';

const my $EARLIER         => '2026-05-23T11:00:00Z';
const my $LATER           => '2026-06-15T12:00:00Z';
const my $NOTIFICATION_ID => '018f1000-0000-7000-8000-00000000d001';

# ADR 0116. event_log, audit_log and notifications are partitioned by
# created_at, and keyed on the id and that time: an id already stored at
# another time is no conflict. PostgreSQL's side is in
# t/integration/postgres-partition-conflicts.t and
# t/integration/postgres-notifications.t; these pin what the writers send
# for it, and that an id they mint themselves costs nothing more.
_caller_event_id_is_locked();
_minted_event_id_is_not_locked();
_caller_event_id_in_open_transaction();
_audit_id_taken_at_another_time();
_audit_id_looked_up_under_the_chain_lock();
_notification_stored_at_another_time();

done_testing();

sub _caller_event_id_is_locked {
    my $schema = GPForum::Test::AuditChainSchema->new;
    _recorder($schema)->record_event( _event( event_id => 'event-1' ) );
    my $journal = $schema->journal;

    is_deeply( [ map { $_->{step} } @{$journal} ],
        [qw(begin lock commit)],
        q{a caller's event id is locked inside a transaction of its own} );
    like(
        $journal->[1]{sql},
        qr/pg_advisory_xact_lock [(] [?], [ ] hashtext/msx,
        'by a transaction advisory lock on the id'
    );
    is( scalar @{ $schema->created_for('EventLog') },
        1, 'and the event is written' );

    return;
}

sub _minted_event_id_is_not_locked {
    my $schema = GPForum::Test::AuditChainSchema->new;
    _recorder($schema)->record_event( _event() );

    is_deeply( $schema->journal, [],
        'an event id the recorder mints is neither locked nor wrapped' );
    is( scalar @{ $schema->created_for('EventLog') },
        1, 'and the event is written' );

    return;
}

sub _caller_event_id_in_open_transaction {
    my $schema = GPForum::Test::AuditChainSchema->new;
    $schema->storage->txn_depth(1);
    _recorder($schema)->record_event( _event( event_id => 'event-1' ) );

    is( $schema->transaction_count,
        0, q{inside the caller's transaction no other is opened} );
    is_deeply( [ map { $_->{step} } @{ $schema->journal } ],
        ['lock'], q{and the event id is locked in the caller's} );

    return;
}

sub _audit_id_taken_at_another_time {
    my $schema   = GPForum::Test::AuditChainSchema->new;
    my $recorder = _recorder($schema);
    my %audit    = (
        action         => 'thread.created',
        actor_id       => 'user-1',
        audit_id       => 'audit-1',
        correlation_id => 'correlation-1',
        created_at     => $EARLIER,
        target_id      => 'thread-1',
        target_type    => 'thread',
    );
    $recorder->record_audit(%audit);
    my $again = $recorder->record_audit( %audit, created_at => $LATER );
    my @taken =
      grep { $_->{audit_id} eq 'audit-1' }
      @{ $schema->created_for('AuditLog') };

    isnt( $again->{audit_id}, 'audit-1',
        'an audit id taken at another time is written under a new id' );
    is( scalar @taken, 1, 'and is stored once' );
    ok(
        $recorder->verify_audit_record($again),
        'and the record under the new id verifies'
    );

    return;
}

# The lookup by audit id cannot race only because the chain lock is already
# held: looked up before it, a writer of the same id at another time could
# commit between the lookup and the lock, and the id was stored twice.
sub _audit_id_looked_up_under_the_chain_lock {
    my $schema   = GPForum::Test::AuditLookupSchema->new;
    my $recorder = _recorder($schema);
    my %audit    = (
        action         => 'thread.created',
        actor_id       => 'user-1',
        audit_id       => 'audit-1',
        correlation_id => 'correlation-1',
        created_at     => $EARLIER,
        target_id      => 'thread-1',
        target_type    => 'thread',
    );
    $recorder->record_audit(%audit);
    @{ $schema->journal } = ();
    $recorder->record_audit( %audit, created_at => $LATER );

    is_deeply(
        [ map { $_->{step} } @{ $schema->journal } ],
        [qw(begin lock lookup commit)],
        q{a caller's audit id is looked up under the audit chain's lock}
    );

    return;
}

sub _notification_stored_at_another_time {
    my $notifications = GPForum::Test::NotificationResultSet->new;
    my $inbox         = GPForum::Test::NotificationResultSet->new;
    my $schema        = GPForum::Test::NotificationTxnSchema->new(
        resultsets => {
            Notification      => $notifications,
            NotificationInbox => $inbox,
            NotificationRead  => GPForum::Test::NotificationResultSet->new,
        },
    );
    $notifications->create(
        {
            created_at        => $EARLIER,
            notification_id   => $NOTIFICATION_ID,
            notification_type => 'reply',
            recipient_user_id => 'user-1',
            source_id         => 'post-1',
            source_type       => 'post',
        }
    );
    my $dispatcher = GPForum::Service::Notification::Dispatcher->new(
        clock             => GPForum::Test::FixedClock->new,
        id_service        => GPForum::Test::Id->new,
        permission_engine => GPForum::Test::PermissionEngine->new,
        schema            => $schema,
    );
    my $delivered = $dispatcher->create_notification(
        {
            notification_id   => $NOTIFICATION_ID,
            notification_type => 'reply',
            recipient_user_id => 'user-1',
            source_id         => 'post-1',
            source_type       => 'post',
        }
    );

    ok( $delivered->{ok} && !$delivered->{duplicate},
        'a notification stored at another time completes its delivery' );
    is( scalar @{ $notifications->created },
        1, 'without writing the notification again' );
    is( $inbox->created->[0]{created_at},
        $EARLIER, 'its inbox row takes the stored time' );
    is( $delivered->{notification}{created_at},
        $EARLIER, 'and the delivery answers with it' );

    return;
}

sub _recorder {
    my ($schema) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => GPForum::Test::Id->new,
        schema     => $schema,
    );
}

sub _event {
    my (%extra) = @_;

    return (
        actor_id          => 'user-1',
        aggregate_id      => 'thread-1',
        aggregate_type    => 'thread',
        aggregate_version => 1,
        event_type        => 'thread.created',
        idempotency_key   => 'thread.created:thread-1',
        payload           => { thread_id => 'thread-1' },
        %extra,
    );
}

1;
