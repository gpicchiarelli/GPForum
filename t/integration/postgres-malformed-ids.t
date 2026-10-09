# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::AdminBootstrap;
use GPForum::Infrastructure::Id;
use GPForum::Service::Password;
use GPForum::Test::PgDatabase;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $HTTP_OK        => 200;
const my $HTTP_NOT_FOUND => 404;
const my $PASSWORD       => 'correct horse battery staple';
const my $STAFF          => 'malformed_id_staff';
const my $JSON           => { Accept => 'application/json' };
const my $MALFORMED      => 'not-a-uuid';

# Well formed and naming no row: the workflow's own not-found.
const my $UNKNOWN => '018f1006-0000-7000-8000-000000000000';

# Every moderation and privacy write route taking an id, by its placeholder.
const my @WRITES => qw(
  /moderation/reports/%s/assign /moderation/reports/%s/release
  /moderation/reports/%s/resolve
  /moderation/posts/%s/hide /moderation/posts/%s/restore
  /moderation/threads/%s/lock /moderation/threads/%s/unlock
  /moderation/threads/%s/hide /moderation/threads/%s/restore
  /moderation/actions/%s/reverse /moderation/users/%s/suspend
  /moderation/suspensions/%s/revoke
  /admin/privacy/deletions/%s/approve /admin/privacy/deletions/%s/hold
  /admin/privacy/erasure/%s/run
);
const my @COUNTS => (
    'SELECT count(*) FROM command_log',
    'SELECT count(*) FROM moderation_actions',
    'SELECT count(*) FROM deletion_actions',
);

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the malformed id test';
}

# A moderation route given an id that is not a uuid answered 500: the
# permission gate bound it as a role binding's resource_id and PostgreSQL
# refused the statement. Revoking a suspension, whose permission is not scoped
# to the path id, and the staff privacy reviews reached their workflow instead
# and answered 503, as if the database were down; the export download
# answered 500. An id that cannot name a row is a 404, decided before any
# statement is sent.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;

my $database = GPForum::Test::PgDatabase->fresh( seed => 1 );
local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;
my $dbh = $database->dbh;

_staff();
my $client = _signed_in();
my $csrf   = _csrf($client);

my @before = _counts();
my %malformed_answer;
for my $route (@WRITES) {
    my $path = sprintf $route, $MALFORMED;
    _post( $client, $path, $csrf );
    $client->status_is( $HTTP_NOT_FOUND, "$path is 404" )
      ->json_is( '/status' => 'not_found' );
    $malformed_answer{$route} = $client->tx->res->json;
}
is_deeply( [ _counts() ],
    \@before,
    'no command, moderation action or deletion action is recorded for them' );

# Word for word: a malformed action id said "action not found", a deletion
# request "request not found" and an erasure job "job not found", where the
# workflow names the missing row in full.
for my $route (@WRITES) {
    my $path = sprintf $route, $UNKNOWN;
    _post( $client, $path, $csrf );
    $client->status_is( $HTTP_NOT_FOUND, "$path, well formed, is 404 too" )
      ->json_is( '/status' => 'not_found' );
    is_deeply(
        $client->tx->res->json,
        $malformed_answer{$route},
        "$path answers as the malformed id did"
    );
}

# The public read routes, and the forum's own writes, given an id that is
# not a uuid: a 404 before any statement, where PostgreSQL refusing the
# bound value answered 500 and wrote the error log.
for my $path (
    "/t/$MALFORMED", "/t/$MALFORMED/some-slug",
    "/c/$MALFORMED", "/attachments/$MALFORMED/download",
    "/t/$UNKNOWN",   "/c/$UNKNOWN",
    "/attachments/$UNKNOWN/download",
  )
{
    $client->get_ok($path)->status_is( $HTTP_NOT_FOUND, "$path is 404" );
}

# Each write with a command id of its own: a second write under the first
# one's id would be its replay, and answered as a conflict.
for my $path ( "/p/$MALFORMED", "/p/$MALFORMED/delete", "/p/$MALFORMED/report" )
{
    $client->post_ok(
        $path => form => {
            body_source => 'An edit',
            command_id  => GPForum::Infrastructure::Id->new->uuid,
            csrf_token  => $csrf,
            reason      => 'spam',
        }
    )->status_is( $HTTP_NOT_FOUND, "$path is 404" );
}

$client->get_ok( "/privacy/export/$MALFORMED" => $JSON )
  ->status_is( $HTTP_NOT_FOUND, 'a malformed export id is 404' );
$client->get_ok( "/privacy/export/$UNKNOWN" => $JSON )
  ->status_is( $HTTP_NOT_FOUND, 'as is an unknown one' );

# The history filters: an id that is not a uuid matches nothing.
$client->get_ok(
    "/moderation/actions?target_type=thread&target_id=$MALFORMED" => $JSON )
  ->status_is( $HTTP_OK, 'a malformed action history filter is a page' )
  ->json_is( '/actions' => [], 'an empty one' );
$client->get_ok(
    "/moderation/suspensions?status=all&user_id=$MALFORMED" => $JSON )
  ->status_is( $HTTP_OK, 'a malformed suspension filter is a page' )
  ->json_is( '/suspensions' => [], 'an empty one' );

done_testing();

sub _post {
    my ( $test_object, $path, $token ) = @_;

    $test_object->post_ok(
        $path => $JSON => form => {
            command_id => GPForum::Infrastructure::Id->new->uuid,
            confirm    => 1,
            csrf_token => $token,
            reason     => 'malformed id',
            resolution => 'dismissed',
        }
    );

    return;
}

sub _counts {
    return map { scalar $dbh->selectrow_array($_) } @COUNTS;
}

sub _csrf {
    my ($test_object) = @_;

    $test_object->get_ok('/moderation/reports')->status_is($HTTP_OK);
    my $page  = $test_object->tx->res->dom;
    my $input = $page->at('input[name=csrf_token]');

    return $input ? $input->attr('value') : q{};
}

sub _signed_in {
    my $test_object = Test::Mojo->new('GPForum');
    $test_object->get_ok('/login');
    my $form = $test_object->tx->res->dom;
    $test_object->post_ok(
        '/login' => form => {
            command_id => $form->at('input[name=command_id]')->attr('value'),
            csrf_token => $form->at('input[name=csrf_token]')->attr('value'),
            identifier => $STAFF,
            password   => $PASSWORD,
        }
    );
    $test_object->get_ok('/settings')
      ->status_is( $HTTP_OK, 'the staff member signs in' );

    return $test_object;
}

# A user with a password, given the bootstrap role: moderation and privacy
# review both.
sub _staff {
    my $hash = GPForum::Service::Password->new->hash_password($PASSWORD);
    my ($id) = $dbh->selectrow_array(
        q{INSERT INTO users (id, username, display_name, email_normalized,}
          . q{ password_hash, status) VALUES (gen_random_uuid(), ?,}
          . q{ 'Malformed id staff', 'malformed-id@example.test', ?,}
          . q{ 'active') RETURNING id},
        undef, $STAFF, $hash
    );
    $dbh->do(
        q{INSERT INTO credentials (id, user_id, type, secret_hash)}
          . q{ VALUES (gen_random_uuid(), ?, 'password', ?)},
        undef, $id, $hash
    );
    is(
        GPForum::Test::PostgresHarness::quietly(
            sub {
                return GPForum::Command::AdminBootstrap->new->run( '--user-id',
                    $id );
            }
        ),
        0,
        'the staff member receives the bootstrap role'
    );

    return $id;
}

1;
