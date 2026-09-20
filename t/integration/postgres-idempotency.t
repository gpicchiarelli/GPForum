package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Community::ReputationLedger;
use GPForum::Test::PostgresHarness;
use GPForum::Worker::EventIdempotencyStore;

our $VERSION = '0.001';

const my $LOCK_TIMEOUT_MS => 10_000;
const my $SEED_USER_SQL   => 'SELECT id FROM users ORDER BY username LIMIT 2';
const my $EVENT_KEY => 'worker.reputation:018f9999-0001-7000-8000-00000000d001';
const my $EVENT_ID  => '018f9999-0001-7000-8000-00000000d001';
const my $REP_SOURCE_ID => '018f9999-0001-7000-8000-00000000d010';
const my $REP_DELTA     => 2;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all =>
      'set GPFORUM_DATABASE_DSN to run the PostgreSQL idempotency test';
}

local $ENV{GPFORUM_DATABASE_LOCK_TIMEOUT_MS}  = $LOCK_TIMEOUT_MS;
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;

my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};

my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0,
    'migrations apply to a clean PostgreSQL database' );
is( $prepared->{seed}, 0, 'small seed profile loads' );

my $case = _load_context($database);
_event_idempotency_key_race($case);
_reputation_source_unique_race($case);

GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _load_context {
    my ($database_info) = @_;

    my $users = $database_info->{dbh}
      ->selectall_arrayref( $SEED_USER_SQL, { Slice => {} } );
    ok( @{$users} >= GPForum::Test::PostgresHarness::worker_count(),
        'seed provides at least two users' );

    return {
        actor_user_id  => $users->[0]{id},
        dbh            => $database_info->{dbh},
        member_user_id => $users->[1]{id},
    };
}

sub _event_idempotency_key_race {
    my ($ctx) = @_;

    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            return _mark_event_key_once();
        }
    );
    _assert_workers_ok( \@outcomes, 'event_idempotency_keys race' );
    my $accepted = grep { $_->{result}{accepted} } @outcomes;
    is(
        $accepted,
        GPForum::Test::PostgresHarness::worker_count(),
        'event_idempotency_keys race accepts both mark_done calls'
    );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh}, 'event_idempotency_keys',
            { idempotency_key => $EVENT_KEY }
        ),
        1,
        'event_idempotency_keys race keeps one key row'
    );

    return;
}

sub _mark_event_key_once {
    my $schema = GPForum::Test::PostgresHarness::connect_schema();
    my $store =
      GPForum::Worker::EventIdempotencyStore->new( schema => $schema );
    my $accepted = $schema->txn_do(
        sub {
            $schema->storage->dbh->do('SELECT pg_sleep(0.05)');
            return $store->mark_done( $EVENT_KEY, { event_id => $EVENT_ID } );
        }
    );

    return {
        accepted => $accepted                   ? 1 : 0,
        done     => $store->is_done($EVENT_KEY) ? 1 : 0,
    };
}

sub _reputation_source_unique_race {
    my ($ctx) = @_;

    my $input = {
        actor_id    => $ctx->{actor_user_id},
        delta       => $REP_DELTA,
        reason      => 'concurrency_reputation',
        source_id   => $REP_SOURCE_ID,
        source_type => 'thread',
        user_id     => $ctx->{member_user_id},
    };
    my @outcomes = GPForum::Test::PostgresHarness::race(
        sub {
            return _record_reputation_once($input);
        }
    );
    _assert_workers_ok( \@outcomes, 'reputation source unique race' );
    my $ok_count = grep { $_->{result}{ok} } @outcomes;
    is(
        $ok_count,
        GPForum::Test::PostgresHarness::worker_count(),
        'reputation source unique race returns ok for both workers'
    );
    _assert_single_id( \@outcomes, 'reputation_event_id',
        'reputation source unique race' );
    is(
        GPForum::Test::PostgresHarness::count_rows(
            $ctx->{dbh},
            'reputation_events',
            {
                source_id   => $input->{source_id},
                source_type => $input->{source_type},
                user_id     => $input->{user_id},
            }
        ),
        1,
        'reputation source unique race keeps one event row'
    );
    my ($score) =
      $ctx->{dbh}->selectrow_array(
        'SELECT score FROM trust_score_snapshots WHERE user_id = ?',
        undef, $input->{user_id}, );
    is( $score, $REP_DELTA,
        'reputation source unique race applies the delta once' );

    return;
}

sub _record_reputation_once {
    my ($input) = @_;

    my $schema   = GPForum::Test::PostgresHarness::connect_schema();
    my $recorded = $schema->txn_do(
        sub {
            $schema->storage->dbh->do('SELECT pg_sleep(0.05)');
            return GPForum::Service::Community::ReputationLedger->new(
                schema => $schema, )->record_event($input);
        }
    );

    return {
        ok                  => $recorded->{ok} ? 1 : 0,
        reputation_event_id => GPForum::Test::PostgresHarness::row_value(
            $recorded->{event}, 'reputation_event_id'
        ),
        skipped => $recorded->{skipped} ? 1 : 0,
        score   => GPForum::Test::PostgresHarness::row_value(
            $recorded->{snapshot}, 'score'
        ),
    };
}

sub _assert_workers_ok {
    my ( $outcomes, $label ) = @_;

    for my $index ( 0 .. $#{$outcomes} ) {
        ok( $outcomes->[$index]{ok},
            "$label worker $index completed without exception" )
          or diag( $outcomes->[$index]{error} // 'missing error' );
    }

    return;
}

sub _assert_single_id {
    my ( $outcomes, $key, $label ) = @_;

    my %ids =
      map  { $_->{result}{$key} => 1 }
      grep { defined $_->{result}{$key} && length $_->{result}{$key} }
      @{$outcomes};
    is( scalar keys %ids, 1, "$label returns one $key" );

    return;
}

1;
