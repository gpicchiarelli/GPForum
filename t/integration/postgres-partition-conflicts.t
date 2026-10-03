# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Digest::SHA qw(sha256_base64);
use English     qw(-no_match_vars);
use POSIX       qw(strftime);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Id;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::PgDatabase;
use GPForum::Test::RacedSchema;

our $VERSION = '0.001';

# A time in each kind of partition: the DEFAULT one, this UTC month's, which
# migrating creates (ADR 0113), and a month this test adds a partition for
# while it runs -- far enough ahead that no migration will have created it
# first.
const my $IN_DEFAULT      => '2026-05-23T12:00:00Z';
const my $IN_THIS_MONTH   => strftime( '%Y-%m-15T12:00:00Z',       gmtime );
const my $THIS_MONTH_PKEY => strftime( 'notifications_%Y_%m_pkey', gmtime );
const my $IN_JANUARY      => '2099-01-15T12:00:00Z';

const my %PARTITION_AT => (
    $IN_DEFAULT    => 'the default partition',
    $IN_THIS_MONTH => 'a monthly partition',
);

const my $RECIPIENT => '018f1000-0000-7000-8000-00000000c001';
const my $ROLL_BACK => 'roll the aborted transaction back';

const my $JANUARY_PARTITION_SQL => join q{ },
  'CREATE TABLE notifications_2099_01 PARTITION OF notifications',
  q{FOR VALUES FROM (TIMESTAMPTZ '2099-01-01 00:00:00+00')},
  q{TO (TIMESTAMPTZ '2099-02-01 00:00:00+00')};

# The test's own table, in its own clone: partitioned twice over, so the row
# lands in a partition of a partition.
const my @LEDGER_SQL => (
    join( q{ },
        'CREATE TABLE test_ledger (entry_id integer NOT NULL,',
        'booked_on date NOT NULL,',
        'CONSTRAINT test_ledger_pkey PRIMARY KEY (entry_id, booked_on))',
        'PARTITION BY RANGE (booked_on)' ),
    join( q{ },
        'CREATE TABLE test_ledger_2026 PARTITION OF test_ledger',
        q{FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')},
        'PARTITION BY RANGE (booked_on)' ),
    join( q{ },
        'CREATE TABLE test_ledger_2026_10 PARTITION OF test_ledger_2026',
        q{FOR VALUES FROM ('2026-10-01') TO ('2026-11-01')} ),
);
const my $LEDGER_ENTRY_SQL =>
  q{INSERT INTO test_ledger (entry_id, booked_on) VALUES (1, '2026-10-15')};

# Another of the test's own, keyed on text, for a key too large to index.
const my @NOTEBOOK_SQL => (
    join( q{ },
        'CREATE TABLE test_notebook (note text NOT NULL,',
        'noted_on date NOT NULL,',
        'CONSTRAINT test_notebook_pkey PRIMARY KEY (note, noted_on))',
        'PARTITION BY RANGE (noted_on)' ),
    'CREATE TABLE test_notebook_default PARTITION OF test_notebook DEFAULT',
);
const my $NOTE_SQL =>
  q{INSERT INTO test_notebook (note, noted_on) VALUES (?, '2026-10-15')};

# Digests do not compress, so a note of this many is too large for a btree
# index row (2704 bytes) and small enough that PostgreSQL names the index.
const my $NOTE_DIGESTS => 75;

const my $NOTIFICATION_ROWS_SQL =>
  'SELECT count(*) FROM notifications WHERE notification_id = ?';
const my $EVENT_ROWS_SQL => 'SELECT count(*) FROM event_log WHERE event_id = ?';
const my $OUTBOX_ROWS_SQL =>
  'SELECT count(*) FROM outbox_messages WHERE event_id = ?';
const my $AUDIT_ROWS_SQL =>
  'SELECT count(*) FROM audit_log WHERE correlation_id = ?';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all =>
      'set GPFORUM_DATABASE_DSN to run the partition conflict test';
}

# event_log, audit_log and notifications are partitioned by created_at, and
# PostgreSQL names the index of the partition a row went to in a unique
# violation -- notifications_default_pkey, event_log_2026_10_pkey -- never
# the table's constraint. The notification dispatcher and the event recorder
# accepted a conflict on their own row by the constraint's name alone, so on
# PostgreSQL each rethrew the conflict it is there to absorb: a leftover
# notification killed its delivery (see postgres-notifications.t), a raced
# event was not reused and a colliding audit id was not minted again. The
# fake ORM raised the name they looked for.
my $database    = GPForum::Test::PgDatabase->fresh;
my $partitioned = {
    conflict => 'GPForum::Infrastructure::UniqueConflict',
    dbh      => $database->dbh,
    ids      => GPForum::Infrastructure::Id->new,
    schema   => $database->schema,
};
_recipient($partitioned);

_partition_conflicts($partitioned);
_other_constraints($partitioned);
_named_in_the_data($partitioned);
_unique_in_the_data($partitioned);
_nested_partitions($partitioned);
_partition_added_later($partitioned);
_inside_a_transaction($partitioned);
_refused_lookup($partitioned);
_raced_event($partitioned);
_colliding_audit_id($partitioned);

done_testing();

sub _recipient {
    my ($ctx) = @_;

    $ctx->{schema}->resultset('User')->create(
        {
            display_name     => 'Recipient',
            email_normalized => 'recipient@example.test',
            id               => $RECIPIENT,
            password_hash    => 'x',
            status           => 'active',
            username         => 'recipient',
        }
    );

    return;
}

sub _partition_conflicts {
    my ($ctx) = @_;

    for my $case (
        [ $IN_DEFAULT,    'notifications_default_pkey' ],
        [ $IN_THIS_MONTH, $THIS_MONTH_PKEY ],
      )
    {
        my ( $time, $index ) = @{$case};
        my $error = _duplicate_notification( $ctx, $time );

        like( $error, qr/"\Q$index\E"/msx,
            "PostgreSQL names $index in the conflict" );
        ok(
            $ctx->{conflict}
              ->is_conflict_on( $ctx->{schema}, $error, 'notifications_pkey' ),
            'and it is a conflict on notifications_pkey'
        );
    }

    return;
}

sub _other_constraints {
    my ($ctx) = @_;

    my $conflict = $ctx->{conflict};
    my $schema   = $ctx->{schema};
    my $error    = _duplicate_notification( $ctx, $IN_THIS_MONTH );
    ok(
        !$conflict->is_conflict_on(
            $schema, $error, 'notification_inbox_pkey'
        ),
        q{a partition's conflict is not one on another table's constraint}
    );
    ok( !$conflict->is_conflict_on( $schema, $error, 'event_log_pkey' ),
        q{nor on another partitioned table's} );

    my $user_error = _duplicate_user( $ctx, 'Recipient again' );
    ok(
        $conflict->is_conflict_on( $schema, $user_error, 'users_pkey' ),
        q{an unpartitioned table's conflict is on its own constraint}
    );
    ok(
        !$conflict->is_conflict_on(
            $schema, $user_error, 'notifications_pkey'
        ),
        q{and not on a partitioned table's}
    );
    ok(
        !$conflict->is_conflict_on(
            $schema, 'connection reset by peer',
            'notifications_pkey'
        ),
        'an error that is no unique violation is a conflict on nothing'
    );

    return;
}

# The DETAIL line and the parameter values DBI appends are the row's data: a
# member's text there is not the server naming a constraint.
sub _named_in_the_data {
    my ($ctx) = @_;

    my $error = _duplicate_user( $ctx, 'notifications_default_pkey' );
    like(
        $error,
        qr/ParamValues: .* notifications_default_pkey/msx,
        q{a users conflict whose values spell a partition's index}
    );
    ok(
        !$ctx->{conflict}
          ->is_conflict_on( $ctx->{schema}, $error, 'notifications_pkey' ),
        'is not taken for a conflict on its table'
    );

    return;
}

# Nor do the values make an error a unique violation. A key too large for its
# index is refused with that index's name on the server's line -- a
# partition's, here -- and a member's note that says "unique constraint" put
# the words is_conflict looks for into the parameter values: the error was
# taken for a conflict on the table, and its row for one already stored.
sub _unique_in_the_data {
    my ($ctx) = @_;

    for my $statement (@NOTEBOOK_SQL) {
        $ctx->{dbh}->do($statement);
    }
    my $note = 'duplicate key value violates unique constraint ' . join q{},
      map { sha256_base64($_) } 1 .. $NOTE_DIGESTS;
    my $error =
      _error( sub { return $ctx->{dbh}->do( $NOTE_SQL, undef, $note ) } );

    like(
        $error,
        qr/index [ ] row [ ] size .* "test_notebook_default_pkey"/msx,
        q{PostgreSQL refuses a key too large for a partition's index}
    );
    ok( $ctx->{conflict}->is_conflict($error),
        'and the note in its values reads as a unique violation' );
    ok(
        !$ctx->{conflict}
          ->is_conflict_on( $ctx->{schema}, $error, 'test_notebook_pkey' ),
        'which is no conflict on the table'
    );

    return;
}

sub _nested_partitions {
    my ($ctx) = @_;

    for my $statement (@LEDGER_SQL) {
        $ctx->{dbh}->do($statement);
    }
    $ctx->{dbh}->do($LEDGER_ENTRY_SQL);
    my $error = _error( sub { return $ctx->{dbh}->do($LEDGER_ENTRY_SQL) } );

    like(
        $error,
        qr/"test_ledger_2026_10_pkey"/msx,
        q{PostgreSQL names the index of a partition's partition}
    );
    ok(
        $ctx->{conflict}
          ->is_conflict_on( $ctx->{schema}, $error, 'test_ledger_pkey' ),
        q{and it is a conflict on the top table's constraint}
    );

    return;
}

# bin/gpforum-partition-maintenance adds next month's partitions while the
# application runs; a family remembered from an earlier conflict would not
# know them.
sub _partition_added_later {
    my ($ctx) = @_;

    $ctx->{dbh}->do($JANUARY_PARTITION_SQL);
    my $error = _duplicate_notification( $ctx, $IN_JANUARY );

    like( $error, qr/"notifications_2099_01_pkey"/msx,
        'PostgreSQL names a partition added after the others were asked about'
    );
    ok(
        $ctx->{conflict}
          ->is_conflict_on( $ctx->{schema}, $error, 'notifications_pkey' ),
        'and it is a conflict on notifications_pkey'
    );

    return;
}

# The stores ask inside their transaction, after the attempt's savepoint
# rolled the conflict back: the catalog lookup has to run there and leave the
# transaction able to commit.
sub _inside_a_transaction {
    my ($ctx) = @_;

    my $schema   = $ctx->{schema};
    my $conflict = $ctx->{conflict};
    my $taken    = _notification( $ctx, $ctx->{ids}->uuid, $IN_THIS_MONTH );
    my $after    = $ctx->{ids}->uuid;
    my $answer   = $schema->txn_do(
        sub {
            my ( undef, $error ) = $conflict->attempt(
                $schema,
                sub {
                    return _notification( $ctx, $taken, $IN_THIS_MONTH );
                }
            );
            my $recognised =
              $conflict->is_conflict_on( $schema, $error,
                'notifications_pkey' );
            _notification( $ctx, $after, $IN_THIS_MONTH );

            return $recognised;
        }
    );

    ok( $answer, 'a conflict is recognised inside the transaction' );
    is( _value( $ctx, $NOTIFICATION_ROWS_SQL, $after ),
        1, 'which goes on to write and commit' );

    return;
}

# Asked without the attempt's savepoint, inside the transaction the conflict
# aborted, PostgreSQL refuses the catalog lookup. The answer falls back to the
# constraint's own name -- the caller rethrows the conflict, as it did before
# partitions were asked about -- and the refusal is not raised in its place.
sub _refused_lookup {
    my ($ctx) = @_;

    my $schema   = $ctx->{schema};
    my $conflict = $ctx->{conflict};
    my $taken    = _notification( $ctx, $ctx->{ids}->uuid, $IN_THIS_MONTH );
    my %answer;
    my $rolled_back = _error(
        sub {
            return $schema->txn_do(
                sub {
                    my $error = _error(
                        sub {
                            return _notification( $ctx, $taken,
                                $IN_THIS_MONTH );
                        }
                    );
                    %answer = (
                        partition => $conflict->is_conflict_on(
                            $schema, $error, $THIS_MONTH_PKEY
                        ),
                        table => $conflict->is_conflict_on(
                            $schema, $error, 'notifications_pkey'
                        ),
                    );
                    croak $ROLL_BACK;
                }
            );
        }
    );

    like( $rolled_back, qr/\Q$ROLL_BACK\E/msx,
        'an aborted transaction asked about its conflict rolls back' );
    ok( !$answer{table},    'without the catalog the table is not recognised' );
    ok( $answer{partition}, 'while the index the server named still is' );

    return;
}

# Another worker commits the same event between the recorder's lookup and its
# insert: the recorder reuses the stored event.
sub _raced_event {
    my ($ctx) = @_;

    my $recorder = GPForum::Infrastructure::EventRecorder->new(
        id_service => $ctx->{ids},
        schema     => $ctx->{schema},
    );
    for my $time ( sort keys %PARTITION_AT ) {
        my $partition = $PARTITION_AT{$time};
        my $event_id  = $ctx->{ids}->uuid;
        my %event     = _event( $ctx, $event_id, $time );
        $recorder->record_event(%event);

        my $raced = GPForum::Test::RacedSchema->new(
            misses => { EventLog => 1 },
            schema => $ctx->{schema},
        );
        my $racing = GPForum::Infrastructure::EventRecorder->new(
            id_service => $ctx->{ids},
            schema     => $raced,
        );
        my $again = eval {
            return $raced->txn_do(
                sub { return $racing->record_event(%event) } );
        };
        my $error = $EVAL_ERROR;

        is( $raced->misses->{EventLog},
            0, "the recorder misses the event in $partition" );
        ok( $again && $again->{skipped},
            'and the conflict on its insert reuses the stored event' )
          or note $error;
        is( $again && $again->{event_id}, $event_id, 'and returns it' );
        is( _value( $ctx, $EVENT_ROWS_SQL, $event_id ),
            1, 'which is stored once' );
        is( _value( $ctx, $OUTBOX_ROWS_SQL, $event_id ),
            1, 'with one outbox row' );
    }

    return;
}

# An audit record whose id and time are already taken is written again under
# a new id, as the fake ORM's audit_log_pkey conflict was.
sub _colliding_audit_id {
    my ($ctx) = @_;

    my $recorder = GPForum::Infrastructure::EventRecorder->new(
        id_service => $ctx->{ids},
        schema     => $ctx->{schema},
    );
    for my $time ( sort keys %PARTITION_AT ) {
        my $partition = $PARTITION_AT{$time};
        my %audit     = (
            action         => 'test.partition_conflict',
            audit_id       => $ctx->{ids}->uuid,
            correlation_id => $ctx->{ids}->uuid,
            created_at     => $time,
            metadata       => { partition => $partition },
            target_id      => $ctx->{ids}->uuid,
            target_type    => 'thread',
        );
        $recorder->record_audit(%audit);
        my $again = eval { return $recorder->record_audit(%audit) };
        my $error = $EVAL_ERROR;

        ok( $again, "an audit id colliding in $partition is written again" )
          or note $error;
        ok( $again && $again->{audit_id} ne $audit{audit_id},
            'under a new id' );
        is( _value( $ctx, $AUDIT_ROWS_SQL, $audit{correlation_id} ),
            2, 'beside the record it collided with' );
    }

    return;
}

sub _event {
    my ( $ctx, $event_id, $time ) = @_;

    my $aggregate = $ctx->{ids}->uuid;

    return (
        aggregate_id      => $aggregate,
        aggregate_type    => 'thread',
        aggregate_version => 1,
        event_id          => $event_id,
        event_type        => 'thread.updated',
        idempotency_key   => "thread.updated:$aggregate",
        payload           => { thread_id => $aggregate },
        timestamp         => $time,
    );
}

sub _duplicate_notification {
    my ( $ctx, $time ) = @_;

    my $id = $ctx->{ids}->uuid;
    _notification( $ctx, $id, $time );

    return _error( sub { return _notification( $ctx, $id, $time ) } );
}

sub _notification {
    my ( $ctx, $id, $time ) = @_;

    $ctx->{schema}->resultset('Notification')->create(
        {
            created_at        => $time,
            notification_id   => $id,
            notification_type => 'reply',
            recipient_user_id => $RECIPIENT,
            source_type       => 'post',
        }
    );

    return $id;
}

# The recipient again, under the same id and a display name of the caller's.
sub _duplicate_user {
    my ( $ctx, $display_name ) = @_;

    return _error(
        sub {
            return $ctx->{schema}->resultset('User')->create(
                {
                    display_name     => $display_name,
                    email_normalized => 'another@example.test',
                    id               => $RECIPIENT,
                    password_hash    => 'x',
                    status           => 'active',
                    username         => 'another',
                }
            );
        }
    );
}

sub _error {
    my ($code) = @_;

    my $done = eval { $code->(); return 1 };
    if ($done) {
        return q{};
    }

    return "$EVAL_ERROR";
}

sub _value {
    my ( $ctx, $sql, @bind ) = @_;

    return scalar $ctx->{dbh}->selectrow_array( $sql, undef, @bind );
}

1;
