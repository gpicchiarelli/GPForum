# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Password;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $HTTP_ACCEPTED     => 202;
const my $HTTP_OK           => 200;
const my $HTTP_UNAUTHORIZED => 401;
const my $COMMAND_ID        => '11111111-2222-4333-8444-555555555555';
const my $PASSWORD          => 'correct horse battery';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the login replay test';
}

# A login used to be an idempotent command whose stored answer held the
# session's bearer token. Replaying the victim's command id with their
# identifier and ANY password signed the attacker in as the victim, and the
# token sat in command_log in plain. Reproduced against the application.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );

my $schema   = GPForum::Test::PostgresHarness::connect_schema();
my $dbh      = $schema->storage->dbh;
my $hash     = GPForum::Service::Password->new->hash_password($PASSWORD);
my ($victim) = $dbh->selectrow_array(
    q{INSERT INTO users (id, username, display_name, email_normalized,}
      . q{ password_hash, status) VALUES (gen_random_uuid(), 'victim',}
      . q{ 'Victim', 'victim@example.test', ?, 'active') RETURNING id},
    undef, $hash
);
$dbh->do(
    q{INSERT INTO credentials (id, user_id, type, secret_hash)}
      . q{ VALUES (gen_random_uuid(), ?, 'password', ?)},
    undef, $victim, $hash
);

is( _login($PASSWORD), $HTTP_ACCEPTED, 'the victim signs in' );
is( _login('the wrong password'),
    $HTTP_UNAUTHORIZED,
    'the same command id and identifier with the wrong password is refused' );
is(
    scalar $dbh->selectrow_array(
q{SELECT count(*) FROM command_log WHERE command_type = 'identity.login'}
    ),
    0,
    'and no login is kept in the command log'
);

# Migration 045 on a database that holds such a row: the token goes, and the
# session it could open is revoked.
my ($exposed) = $dbh->selectrow_array(
    q{INSERT INTO sessions (session_id, user_id, session_hash, expires_at)}
      . q{ VALUES (gen_random_uuid(), ?, 'hash-exposed', now() + interval '1 day')}
      . q{ RETURNING session_id},
    undef, $victim
);
$dbh->do(
    q{INSERT INTO command_log (command_id, command_type, correlation_id,}
      . q{ idempotency_key, payload) VALUES (gen_random_uuid(), 'identity.login',}
      . q{ gen_random_uuid(), 'login-exposed', jsonb_build_object('response',}
      . q{ jsonb_build_object('stored', jsonb_build_object('session_id', ?::text,}
      . q{ 'session_token', 'raw-bearer-token'))))},
    undef, $exposed
);
$dbh->do( path('migrations/045_scrub_login_sessions.sql')->slurp );
is(
    scalar $dbh->selectrow_array(
q{SELECT count(*) FROM command_log WHERE payload::text LIKE '%raw-bearer-token%'}
    ),
    0,
    'migration 045 removes stored session tokens'
);
ok(
    scalar $dbh->selectrow_array(
        'SELECT revoked_at IS NOT NULL FROM sessions WHERE session_id = ?',
        undef, $exposed
    ),
    'and revokes the sessions they could open'
);

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

# One login from a fresh client with the fixed command id; the status, and
# whether the client is signed in afterwards.
sub _login {
    my ($password) = @_;

    my $client = Test::Mojo->new('GPForum');
    $client->get_ok('/login');
    my $page = $client->tx->res->dom;
    my $csrf = $page->at('input[name=csrf_token]')->attr('value');
    $client->post_ok(
        '/login' => form => {
            command_id => $COMMAND_ID,
            csrf_token => $csrf,
            identifier => 'victim',
            password   => $password,
        }
    );
    my $status = $client->tx->res->code;
    $client->get_ok('/settings');
    my $signed_in  = $client->tx->res->code == $HTTP_OK ? 1 : 0;
    my $app_schema = $client->app->build_controller->gp_schema;
    $app_schema->storage->disconnect;

    return $status == $HTTP_ACCEPTED && $signed_in ? $HTTP_ACCEPTED : $status;
}

1;
