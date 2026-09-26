# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Mojo::File;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::PostgresHarness;
use GPForum::Worker::Handler::ThreadActivity;

our $VERSION = '0.001';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the thread activity test';
}

# threads.last_activity_at had no writer, so "latest activity" was creation
# order. Migration 046 sets existing threads to their latest visible post,
# and the outbox's ThreadActivity handler moves a thread up on each reply.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );
is( $prepared->{seed},    0, 'the seed loads' );

my $schema = GPForum::Test::PostgresHarness::connect_schema();
my $dbh    = $schema->storage->dbh;

$dbh->do('UPDATE threads SET last_activity_at = created_at');
$dbh->do(
    Mojo::File->new('migrations/046_thread_last_activity_backfill.sql')
      ->slurp );
is(
    scalar $dbh->selectrow_array(
            q{SELECT count(*) FROM threads t WHERE t.last_activity_at <}
          . q{ (SELECT max(p.created_at) FROM posts p WHERE p.thread_id =}
          . q{ t.thread_id AND p.deleted_at IS NULL}
          . q{ AND p.moderation_state = 'visible')}
    ),
    0,
    'migration 046 sets every thread to its latest reply'
);

my ($thread) = $dbh->selectrow_array('SELECT thread_id FROM threads LIMIT 1');
my $handler =
  GPForum::Worker::Handler::ThreadActivity->new( schema => $schema );
my %reply = (
    domain_payload => { thread_id => $thread },
    event_type     => 'post.created',
);
ok( $handler->supports( \%reply ), 'a reply is handled' );
ok( !$handler->supports( { %reply, event_type => 'post.updated' } ),
    'an edit is not' );

$handler->handle( { %reply, occurred_at => '2031-01-01T00:00:00Z' } );
is( _activity(), '2031-01-01 00:00:00+00', 'a reply moves its thread up' );
$handler->handle( { %reply, occurred_at => '2030-01-01T00:00:00Z' } );
is(
    _activity(),
    '2031-01-01 00:00:00+00',
    'an older reply delivered late does not move it back'
);
$handler->handle( { %reply, occurred_at => '2031-01-01T00:00:00Z' } );
is( _activity(), '2031-01-01 00:00:00+00', 'and a repeat changes nothing' );

my $app = Test::Mojo->new('GPForum')->app;
ok(
    (
        grep { ref $_ eq 'GPForum::Worker::Handler::ThreadActivity' }
          @{ $app->build_controller->gp_outbox_transport->handlers }
    ),
    'the application dispatches replies to it'
);

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _activity {
    $dbh->do(q{SET TIME ZONE 'UTC'});
    return
      scalar $dbh->selectrow_array(
        'SELECT last_activity_at::text FROM threads WHERE thread_id = ?',
        undef, $thread );
}

1;
