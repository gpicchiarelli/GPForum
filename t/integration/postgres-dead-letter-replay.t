# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::DeadLetterReplay;
use GPForum::Command::Migrate;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Id;
use GPForum::Service::Admin::ConsoleReader;
use GPForum::Service::Admin::Workflow;
use GPForum::Service::Operations::CommandIdempotency;
use GPForum::Service::Outbox::DeadLetterReplay;
use GPForum::Service::Outbox::Dispatcher;
use GPForum::Test::FailingAuditRecorder;
use GPForum::Test::OutboxTransport;
use GPForum::Test::QuietLog;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $ADMIN          => '018f1000-0000-7000-8000-00000000ad01';
const my $UNKNOWN        => '018f1000-0000-7000-8000-0000000000ff';
const my $EXIT_OK        => 0;
const my $EXIT_FAILURE   => 1;
const my $DISPATCH_BATCH => 100;
const my $LIST_LIMIT     => 50;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all =>
      'set GPFORUM_DATABASE_DSN to run the dead-letter replay test';
}

# ADR 0056's replay against PostgreSQL, from a dead letter the real dispatcher
# made: the replay is a new message for the same envelope, the evidence stays,
# the audit log records it, a dead letter replays once, and the replay works
# after retention has purged the cancelled message.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
GPForum::Test::PostgresHarness::quietly(
    sub { return GPForum::Command::Migrate->new->run('--apply') } );

my $schema = GPForum::Test::PostgresHarness::connect_schema();
my $dbh    = $schema->storage->dbh;
my $replay =
  GPForum::Service::Outbox::DeadLetterReplay->new( schema => $schema );

my $first = _dead_letter('first');
is(
    _value(
        'SELECT status FROM outbox_messages WHERE outbox_id = ?',
        $first->{source_id}
    ),
    'cancelled',
    'the dispatcher cancelled the message it could not deliver'
);

my $outcome = $replay->replay(
    {
        actor_user_id  => $ADMIN,
        dead_letter_id => $first->{dead_letter_id},
        via            => 'web',
    }
);
is( $outcome->{status}, 'replayed', 'a dead letter is replayed' );
my $replayed_id = $outcome->{replayed}{outbox_id};
isnt( $replayed_id, $first->{source_id}, 'as a new outbox message' );
is_deeply(
    [
        $dbh->selectrow_array(
            'SELECT r.status, r.event_id = o.event_id, r.payload = o.payload,'
              . ' r.queue = o.queue, r.job_type = o.job_type,'
              . ' r.idempotency_key, r.attempt_count'
              . ' FROM outbox_messages r, outbox_messages o'
              . ' WHERE r.outbox_id = ? AND o.outbox_id = ?',
            undef,
            $replayed_id,
            $first->{source_id}
        )
    ],
    [ 'pending', 1, 1, 1, 1, "dead-letter-replay:$first->{dead_letter_id}", 0 ],
    'pending, for the same event, envelope and job, with a fresh budget'
);
is(
    _value(
        'SELECT status FROM outbox_messages WHERE outbox_id = ?',
        $first->{source_id}
    ),
    'cancelled',
    'the cancelled message is left as it was'
);
is(
    _value(
        'SELECT count(*) FROM dead_letters WHERE dead_letter_id = ?',
        $first->{dead_letter_id}
    ),
    1,
    'and so is the dead letter'
);
is_deeply(
    [
        $dbh->selectrow_array(
            q{SELECT actor_id, target_type, metadata->>'via',}
              . q{ metadata->>'outbox_id' FROM audit_log}
              . q{ WHERE action = 'outbox.dead_letter_replayed'}
              . q{ AND target_id = ?},
            undef,
            $first->{dead_letter_id}
        )
    ],
    [ $ADMIN, 'dead_letter', 'web', $replayed_id ],
    'the audit log records who replayed it, how, and as what'
);

my $again = $replay->replay( { dead_letter_id => $first->{dead_letter_id} } );
is( $again->{status}, 'conflict', 'a dead letter replays once' );
like( $again->{error}, qr/\Q$replayed_id\E/msx, 'and says as what' );
is( $replay->replay( { dead_letter_id => $UNKNOWN } )->{status},
    'not_found', 'an unknown dead letter is not found' );
is( $replay->replay( { dead_letter_id => 'not-a-uuid' } )->{status},
    'not_found',
    'nor is a value that is not a uuid, without a database error' );

my $reader = GPForum::Service::Admin::ConsoleReader->new( schema => $schema );
is( _replay_status( $reader, $first->{dead_letter_id} ),
    'pending', 'the console shows the replay pending' );

my $delivered = _dispatch( {} );
ok(
    ( grep { $_ eq $replayed_id } @{$delivered} ),
    'the dispatcher delivers the replay'
);
is( _replay_status( $reader, $first->{dead_letter_id} ),
    'done', 'and the console shows it done' );

# Retention purges a delivered replay after seven days, as it does every done
# message, and keeps the dead letter for thirty. The replay must stay
# replayed: the audit log, which is never purged, remembers it.
$dbh->do( 'DELETE FROM outbox_messages WHERE outbox_id = ?',
    undef, $replayed_id );
is(
    $replay->replay( { dead_letter_id => $first->{dead_letter_id} } )->{status},
    'conflict',
    'a dead letter still replays once after its replay was purged'
);
is( _replay_status( $reader, $first->{dead_letter_id} ),
    'replayed', 'and the console still shows it replayed' );

# Retention purges a cancelled message after seven days and keeps its dead
# letter for thirty. The replay needs only the dead letter.
my $purged = _dead_letter('purged');
$dbh->do( 'DELETE FROM outbox_messages WHERE outbox_id = ?',
    undef, $purged->{source_id} );
is(
    $replay->replay( { dead_letter_id => $purged->{dead_letter_id} } )
      ->{status},
    'replayed',
    'a dead letter replays after its cancelled message was purged'
);

# The shell: review, then replay, audited with no actor and via=cli.
my $shell   = _dead_letter('shell');
my $command = GPForum::Command::DeadLetterReplay->new( schema => $schema );
my ( $listed, $list_status ) = _capture( sub { $command->run('--list') } );
is( $list_status, $EXIT_OK, 'the shell lists dead letters' );
like(
    $listed,
    qr/^\Q$shell->{dead_letter_id}\E [ ] .* replay=none/msx,
    'with the ones not yet replayed'
);
like(
    $listed,
    qr/^\Q$first->{dead_letter_id}\E [ ] .* replay=replayed/msx,
    'and which were replayed'
);
like(
    $listed,
    qr/^\Q$shell->{dead_letter_id}\E [ ] .* type=permanent/msx,
    'with the failure type the runbook says to read first'
);

my ( $said, $replay_status ) =
  _capture( sub { $command->run( '--id', $shell->{dead_letter_id} ) } );
is( $replay_status, $EXIT_OK, 'the shell replays a dead letter' );
like( $said, qr/\A replayed [ ] \Q$shell->{dead_letter_id}\E/msx,
    'and says so' );
is_deeply(
    [
        $dbh->selectrow_array(
            q{SELECT actor_id, metadata->>'via' FROM audit_log}
              . q{ WHERE action = 'outbox.dead_letter_replayed'}
              . q{ AND target_id = ?},
            undef,
            $shell->{dead_letter_id}
        )
    ],
    [ undef, 'cli' ],
    'audited with no actor, via the shell'
);
my ( $refused, $refused_status ) =
  _capture( sub { $command->run( '--id', $shell->{dead_letter_id} ) } );
is( $refused_status, $EXIT_FAILURE, 'a refused replay exits 1' );
like( $refused, qr/\A not [ ] replayed .* conflict/msx, 'and says why' );

# From the console the replay runs inside the command's transaction. A
# failure after the new message is written -- here, the audit -- must take
# the message and the command with it, or the work is queued with no record
# of who asked, and the command id answers "failed" for good.
my $atomic   = _dead_letter('atomic');
my $workflow = GPForum::Service::Admin::Workflow->new(
    command_idempotency =>
      GPForum::Service::Operations::CommandIdempotency->new(
        schema => $schema
      ),
    dead_letter_replay => GPForum::Service::Outbox::DeadLetterReplay->new(
        recorder => GPForum::Test::FailingAuditRecorder->new,
        schema   => $schema,
    ),
    logger => GPForum::Test::QuietLog->new,
);
my $failed = $workflow->replay_dead_letter(
    {
        actor_user_id  => $ADMIN,
        command_id     => 'replay-atomic-1',
        dead_letter_id => $atomic->{dead_letter_id},
    }
);
is( $failed->{status}, 'failed', 'a replay whose audit fails fails' );
is(
    _value(
        'SELECT count(*) FROM outbox_messages WHERE idempotency_key = ?',
        GPForum::Service::Outbox::DeadLetterReplay->replay_key(
            $atomic->{dead_letter_id}
        )
    ),
    0,
    'and leaves no replay message behind'
);
is(
    _value(
        'SELECT count(*) FROM command_log WHERE idempotency_key = ?',
        'replay-atomic-1'
    ),
    0,
    'nor a stored answer for its command id, so a retry can succeed'
);

$dbh->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

# An event the recorder writes, and a dispatch that fails it permanently: the
# dispatcher cancels the message and records the dead letter, as in
# production.
sub _dead_letter {
    my ($label) = @_;

    my $id       = GPForum::Infrastructure::Id->new;
    my $category = $id->uuid;
    GPForum::Infrastructure::EventRecorder->new(
        id_service => $id,
        schema     => $schema,
    )->record_event(
        actor_id          => $ADMIN,
        aggregate_id      => $category,
        aggregate_type    => 'category',
        aggregate_version => 1,
        event_type        => 'category.updated',
        idempotency_key   => "category.updated:$label:$category",
        payload           => { category_id => $category, title => $label },
    );
    my ($outbox_id) = $dbh->selectrow_array(
        'SELECT outbox_id FROM outbox_messages WHERE event_id IN'
          . ' (SELECT event_id FROM event_log WHERE aggregate_id = ?)',
        undef, $category
    );

    # The dispatcher's clock counts whole seconds, so a message written in
    # the current second is not yet due to it.
    $dbh->do(
q{UPDATE outbox_messages SET next_attempt_at = now() - interval '1 minute'}
          . q{ WHERE outbox_id = ?},
        undef, $outbox_id
    );
    _dispatch( { $outbox_id => 'permanent' } );
    my ($dead_letter_id) = $dbh->selectrow_array(
        'SELECT dead_letter_id FROM dead_letters WHERE source_id = ?',
        undef, $outbox_id );

    return { dead_letter_id => $dead_letter_id, source_id => $outbox_id };
}

sub _dispatch {
    my ($failures) = @_;

    my $transport = GPForum::Test::OutboxTransport->new(
        fail_ids   => { map { $_ => 1 } keys %{$failures} },
        fail_types => $failures,
    );
    GPForum::Service::Outbox::Dispatcher->new(
        id_service => GPForum::Infrastructure::Id->new,
        schema     => $schema,
        transport  => $transport,
    )->dispatch_pending($DISPATCH_BATCH);

    return $transport->delivered;
}

sub _replay_status {
    my ( $console, $dead_letter_id ) = @_;

    my ($letter) = grep { $_->{dead_letter_id} eq $dead_letter_id }
      @{ $console->list_dead_letters( { limit => $LIST_LIMIT } ) };

    return $letter ? $letter->{replay_status} : undef;
}

sub _value {
    my ( $sql, @binds ) = @_;

    my ($value) = $dbh->selectrow_array( $sql, undef, @binds );

    return $value;
}

sub _capture {
    my ($code) = @_;

    my $output = q{};
    open my $handle, '>', \$output or croak 'failed to capture stdout';
    my $status;
    {
        local *STDOUT = $handle;
        $status = $code->();
    }
    close $handle or croak 'failed to close stdout capture';

    return ( $output, $status );
}

1;
