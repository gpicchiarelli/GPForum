# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::EventIdempotencySchema;
use GPForum::Test::Id;
use GPForum::Test::ScriptedWriteSchema;
use GPForum::Worker::EventIdempotencyStore;
use GPForum::X::Conflict;

our $VERSION = '0.001';

# The event recorder and the event idempotency store recover from a unique
# violation only on the constraint they were writing, asked of the
# GPForum::X::Conflict that UniqueConflict->attempt returns. A violation of
# any other constraint, and any error that is no violation at all, reaches
# the caller unchanged. Each case scripts the conflict a create raises -- a
# conflict exception, or the plain text a fake ORM dies with -- and counts
# the writes that followed it.

my $outbox_key = 'outbox_messages_idempotency_key_key';
my %event      = (
    actor_id       => 'user-1',
    aggregate_id   => 'thread-1',
    aggregate_type => 'thread',
    correlation_id => 'correlation-1',
    event_type     => 'thread.created',
    payload        => { category_id => 'category-1' },
    timestamp      => '2026-10-03T08:00:00Z',
);
my %audit = (
    action         => 'thread.created',
    actor_id       => 'user-1',
    correlation_id => 'correlation-1',
    metadata       => { title => 'Welcome' },
    target_id      => 'thread-1',
    target_type    => 'thread',
);

subtest 'an outbox id taken is minted again' => sub {
    my ( $schema, $recorder ) = _recorder();
    _script( $schema, 'OutboxMessage', _thrown('outbox_messages_pkey') );

    my $event  = $recorder->record_event(%event);
    my $outbox = $schema->resultset('OutboxMessage')->created;
    is( scalar @{$outbox},      1, 'the retry writes the message' );
    is( $outbox->[0]{event_id}, $event->{event_id}, 'for the event' );
};

subtest 'an outbox key taken reuses the stored message' => sub {
    my ( $schema, $recorder ) = _recorder();
    _script( $schema, 'OutboxMessage', _violation($outbox_key) );
    $schema->resultset('OutboxMessage')
      ->found_after_failure( { outbox_id => 'stored-outbox' } );

    ok( $recorder->record_event(%event), 'the event is recorded' );
    is( scalar @{ $schema->resultset('OutboxMessage')->created },
        0, 'and no second message is written for the key' );
};

subtest 'an outbox key taken by nothing left is raised' => sub {
    my ( $schema, $recorder ) = _recorder();
    my $violation = _violation($outbox_key);
    _script( $schema, 'OutboxMessage', $violation );

    my $error    = _error_of( sub { $recorder->record_event(%event) } );
    my $conflict = GPForum::X::Conflict->caught($error);
    ok( $conflict,                               'as a conflict' );
    ok( $conflict && $conflict->on($outbox_key), 'on the key' );
    is( "$error", $violation, 'in the words the server used' );
    is( scalar @{ $schema->resultset('OutboxMessage')->created },
        0, 'and no message is written under a fresh id' );
};

subtest 'an outbox conflict on another constraint is raised' => sub {
    my ( $schema, $recorder ) = _recorder();
    my $violation = _violation('outbox_messages_event_id_key');
    _script( $schema, 'OutboxMessage', $violation );
    $schema->resultset('OutboxMessage')
      ->found_after_failure( { outbox_id => 'stored-outbox' } );

    my $error = _error_of( sub { $recorder->record_event(%event) } );
    is( "$error", $violation, 'unchanged, though a message is stored' );
    is( scalar @{ $schema->resultset('OutboxMessage')->created },
        0, 'and nothing is retried' );
};

subtest 'an outbox write that is no conflict is raised' => sub {
    my ( $schema, $recorder ) = _recorder();
    _script( $schema, 'OutboxMessage', "disk full\n" );

    my $error = _error_of( sub { $recorder->record_event(%event) } );
    like( $error, qr/\A disk [ ] full$/msx, 'as it was raised' );
    ok( !GPForum::X::Conflict->caught($error), 'not as a conflict' );
};

subtest 'an event id taken is minted again' => sub {
    my ( $schema, $recorder ) = _recorder();
    _script( $schema, 'EventLog', _violation('event_log_pkey') );

    my $event = $recorder->record_event(%event);
    my $log   = $schema->resultset('EventLog')->created;
    is( scalar @{$log},      1,                  'the retry writes the event' );
    is( $log->[0]{event_id}, $event->{event_id}, 'under the id returned' );
    is( $log->[0]{metadata}{event_id},
        $event->{event_id},
        'and its metadata names that id, not the taken one' );
};

subtest 'an event conflict on another constraint is raised' => sub {
    my ( $schema, $recorder ) = _recorder();
    my $violation = _violation('event_log_idempotency_key_key');
    _script( $schema, 'EventLog', $violation );

    my $error = _error_of( sub { $recorder->record_event(%event) } );
    is( "$error", $violation, 'unchanged' );
    is( scalar @{ $schema->resultset('EventLog')->created },
        0, 'and the event is not written under a fresh id' );
    is( scalar @{ $schema->resultset('OutboxMessage')->created },
        0, 'nor its message' );
};

subtest 'an audit id taken is minted again' => sub {
    my ( $schema, $recorder ) = _recorder();
    _script( $schema, 'AuditLog', _thrown('audit_log_pkey') );

    my $audit = $recorder->record_audit(%audit);
    my $log   = $schema->resultset('AuditLog')->created;
    is( scalar @{$log},      1, 'the retry writes the audit row' );
    is( $log->[0]{audit_id}, $audit->{audit_id}, 'under the id returned' );
};

subtest 'an audit conflict on another constraint is raised' => sub {
    my ( $schema, $recorder ) = _recorder();
    my $violation = _violation('audit_log_record_hash_key');
    _script( $schema, 'AuditLog', $violation );

    my $error = _error_of( sub { $recorder->record_audit(%audit) } );
    is( "$error", $violation, 'unchanged' );
    is( scalar @{ $schema->resultset('AuditLog')->created },
        0, 'and the row is not written under a fresh id' );
};

subtest 'an event key claimed elsewhere is no claim of ours' => sub {
    my $schema = GPForum::Test::EventIdempotencySchema->new;
    my $store =
      GPForum::Worker::EventIdempotencyStore->new( schema => $schema );

    $schema->keys->fail_error( _violation('event_idempotency_keys_pkey') );
    is( $store->begin('worker.search:event-1'),
        0, 'a conflict on the key is another worker holding it' );
    is(
        $store->mark_done( 'worker.search:event-1', { event_id => 'event-1' } ),
        1,
        'and a completion someone else recorded is absorbed'
    );

    my $other = _violation('event_idempotency_keys_other_key');
    $schema->keys->fail_error($other);
    like( _error_of( sub { $store->begin('worker.search:event-2') } ),
        qr/\A\Q$other\E/msx, 'a conflict on any other constraint is raised' );
    like(
        _error_of(
            sub {
                $store->mark_done( 'worker.search:event-2',
                    { event_id => 'event-2' } );
            }
        ),
        qr/\A\Q$other\E/msx,
        'by a completion too'
    );
};

done_testing();

sub _recorder {
    my $schema = GPForum::Test::ScriptedWriteSchema->new;

    return (
        $schema,
        GPForum::Infrastructure::EventRecorder->new(
            id_service => GPForum::Test::Id->new,
            schema     => $schema,
        )
    );
}

sub _script {
    my ( $schema, $source, @errors ) = @_;

    push @{ $schema->resultset($source)->failures }, @errors;

    return;
}

# The text PostgreSQL's unique violation starts with, as DBI reports it.
sub _violation {
    my ($index) = @_;

    return 'DBD::Pg::st execute failed: ERROR:  duplicate key value violates'
      . qq{ unique constraint "$index"\n};
}

# The conflict a fake ORM raises through UniqueConflict->throw.
sub _thrown {
    my ($constraint) = @_;

    return _error_of(
        sub { GPForum::Infrastructure::UniqueConflict->throw($constraint) } );
}

sub _error_of {
    my ($code) = @_;

    try {
        $code->();
    }
    catch ($error) {
        return $error;
    };

    return undef;
}

1;
