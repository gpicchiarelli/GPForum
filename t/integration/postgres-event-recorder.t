# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Migrate;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Id;
use GPForum::Service::Admin::CategoryStore;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $ACTOR => '018f1000-0000-7000-8000-00000000e001';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the event recorder test';
}

# Recording an event whose event_id is already stored -- a retried write after
# a crash between the event and its outbox row -- must reuse the stored event
# and leave exactly one event and one outbox row. The path read the stored row
# as a hash, which only the test doubles return: against PostgreSQL it saw no
# columns and tried to insert an outbox row with no event.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
GPForum::Test::PostgresHarness::quietly(
    sub { return GPForum::Command::Migrate->new->run('--apply') } );

my $schema   = GPForum::Test::PostgresHarness::connect_schema();
my $dbh      = $schema->storage->dbh;
my $id       = GPForum::Infrastructure::Id->new;
my $recorder = GPForum::Infrastructure::EventRecorder->new(
    id_service => $id,
    schema     => $schema,
);
my $event_id  = $id->uuid;
my $aggregate = $id->uuid;
my %event     = (
    actor_id          => $ACTOR,
    aggregate_id      => $aggregate,
    aggregate_type    => 'category',
    aggregate_version => 1,
    event_id          => $event_id,
    event_type        => 'category.updated',
    idempotency_key   => "category.updated:$aggregate",
    payload           => { category_id => $aggregate },
);

my $first = $recorder->record_event(%event);
is( $first->{event_id}, $event_id, 'the event is recorded' );

my $again = $recorder->record_event(%event);
ok( $again->{skipped}, 'recording it again reuses the stored event' );
is( $again->{event_id}, $event_id, 'and returns it' );

$dbh->do( 'DELETE FROM outbox_messages WHERE event_id = ?', undef, $event_id );
my $recovered = $recorder->record_event(%event);
ok( $recovered->{skipped}, 'an event whose outbox row is missing is reused' );
is(
    scalar $dbh->selectrow_array(
        'SELECT count(*) FROM outbox_messages WHERE event_id = ?', undef,
        $event_id
    ),
    1,
    'and gets its outbox row back'
);
is(
    scalar $dbh->selectrow_array(
        'SELECT count(*) FROM event_log WHERE event_id = ?', undef,
        $event_id
    ),
    1,
    'with still one event'
);

# ADR 0110's append_once: a write whose row was stored but whose event was
# lost records the event when the command is replayed -- once, and only
# then. Six stores share EventRecorder::event_recorded for that lookup.
ok(
    $recorder->event_recorded("category.updated:$aggregate"),
    'event_recorded finds an event by its idempotency key'
);
ok( !$recorder->event_recorded("category.updated:$event_id"),
    'and not one that was never recorded' );

$dbh->do(
    q{INSERT INTO users (id, username, display_name, email_normalized,}
      . q{ password_hash, status) VALUES (?, 'recorder-admin', 'Recorder',}
      . q{ 'recorder@example.test', 'x', 'active') ON CONFLICT DO NOTHING},
    undef, $ACTOR
);
my $store = GPForum::Service::Admin::CategoryStore->new( schema => $schema );
my %input = ( actor_user_id => $ACTOR, title => 'Event recorder board' );
my $key =
  'category.created:' . $store->create_category( {%input} )->{category_id};
$dbh->do(
    'DELETE FROM outbox_messages WHERE event_id IN'
      . ' (SELECT event_id FROM event_log WHERE idempotency_key = ?)',
    undef, $key
);
$dbh->do( 'DELETE FROM event_log WHERE idempotency_key = ?', undef, $key );
ok( !$recorder->event_recorded($key),
    'a category whose event is lost, as in a crash' );
ok(
    $store->create_category( {%input} )->{idempotent},
    'repeating the command reuses the stored category'
);
is( _events($key), 1, 'and records the lost event' );
$store->create_category( {%input} );
is( _events($key), 1, 'only once' );

$dbh->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _events {
    my ($idempotency_key) = @_;

    return
      scalar $dbh->selectrow_array(
        'SELECT count(*) FROM event_log WHERE idempotency_key = ?',
        undef, $idempotency_key );
}

1;
