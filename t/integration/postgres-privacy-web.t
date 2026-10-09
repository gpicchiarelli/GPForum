# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Password;
use GPForum::Service::Portability::ExportBundleBuilder;
use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

const my $HTTP_OK        => 200;
const my $HTTP_NOT_FOUND => 404;
const my $PASSWORD       => 'correct horse battery staple';
const my $MEMBER         => 'privacy_web_member';
const my $EMAIL          => 'privacy-web@example.test';
const my $JSON           => { Accept => 'application/json' };

const my $MEMBER_SQL => join q{ },
  'INSERT INTO users (id, username, display_name, email_normalized,',
  q{password_hash, status) VALUES (gen_random_uuid(), ?, 'Privacy member',},
  q{?, ?, 'active') RETURNING id};
const my $CREDENTIAL_SQL => join q{ },
  'INSERT INTO credentials (id, user_id, type, secret_hash)',
  q{VALUES (gen_random_uuid(), ?, 'password', ?)};
const my $POST_SQL => join q{ },
  'INSERT INTO posts (post_id, thread_id, author_user_id, position)',
  'SELECT gen_random_uuid(), thread_id, ?,',
  '(SELECT coalesce(max(position), 0) + 1 FROM posts p',
  'WHERE p.thread_id = t.thread_id)',
  'FROM threads t ORDER BY t.created_at LIMIT 1 RETURNING post_id';
const my $BODY_SQL => join q{ },
  'INSERT INTO post_bodies (body_id, post_id, body_source,',
  q{body_rendered_safe, source_hash)},
  q{VALUES (gen_random_uuid(), ?, 'Exported post', '<p>Exported post</p>',},
  q{'hash')};

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the privacy web test';
}

# The member's privacy dashboard and export download against PostgreSQL. The
# manifest is a jsonb column, and the dashboard, the download and the export
# store read it with get_column, which returns the column's text: the
# dashboard's $request->{manifest}{counts} died under strict refs for any
# member with any export request -- the page answered an error -- and the
# download sent the whole bundle as one JSON string. The doubles behind
# t/62-privacy-web.t hand the manifest over as a hash and never showed it.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;

my $database = GPForum::Test::PgDatabase->fresh( seed => 1 );
local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;
my $dbh = $database->dbh;

my $member  = _member();
my $exports = GPForum::Service::Portability::ExportBundleBuilder->new(
    schema => $database->schema );
my $completed = $exports->complete_user_export(
    $exports->request_user_export($member)->{export_request_id} );
is( $completed->{status}, 'completed', 'the member has a completed export' );
my $pending = $exports->request_user_export($member);
is( $pending->{status}, 'pending', 'and a pending one' );

my $client = _signed_in();
$client->get_ok('/privacy')
  ->status_is( $HTTP_OK, 'the dashboard renders for a member with exports' );
my $page = $client->tx->res->dom;
my $listed =
  $page->find('ol.ui-card-list li article')
  ->map( attr => 'aria-labelledby' )
  ->to_array;
is( scalar @{$listed}, 2, 'listing both exports' );
like(
    $page->at('main')->all_text,
    qr/1, [^,]+ 0, [^,]+ 0, [^,]+ 0[.]/msx,
    'the completed one with the counts from its manifest'
);
my $download = "/privacy/export/$completed->{export_request_id}";
ok( $page->at(qq{a[href="$download"]}),
    'and a download link for the completed one only' );
is( $page->find('a[href^="/privacy/export/"]')->size,
    1, 'none for the pending one' );

$client->get_ok( '/privacy' => $JSON )->status_is($HTTP_OK);
my $dashboard = $client->tx->res->json;
my %by_status = map { $_->{status} => $_ } @{ $dashboard->{export_requests} };
is( $by_status{completed}{manifest}{counts}{posts},
    1, 'the dashboard JSON carries the manifest as an object' );
is_deeply( $by_status{pending}{manifest},
    {}, 'and the pending export an empty one' );

$client->get_ok($download)
  ->status_is( $HTTP_OK, 'the download answers' )
  ->content_type_like( qr{\A application/json}msx, 'as JSON' );
my $bundle = $client->tx->res->json;
is( ref $bundle, 'HASH', 'the bundle is a JSON object, not a JSON string' );
is( $bundle->{profile}{email}, $EMAIL, 'holding the member\'s profile' );
is_deeply( [ map { $_->{body_source} } @{ $bundle->{posts} || [] } ],
    ['Exported post'], 'and their posts' );
is( $bundle->{counts}{posts}, 1, 'with the counts' );

$client->get_ok( "/privacy/export/$pending->{export_request_id}" => $JSON )
  ->status_is( $HTTP_NOT_FOUND, 'a pending export cannot be downloaded' );

# The export route, through the application's own wiring: it takes the
# member's account row before it writes, finishes the pending export and
# answers the bundle as an object; the same command id replays it.
my $export_button = $page->at('form[action="/privacy/export"]');
my %export_form   = (
    command_id => $export_button->at('input[name=command_id]')->attr('value'),
    csrf_token => $export_button->at('input[name=csrf_token]')->attr('value'),
);
$client->post_ok( '/privacy/export' => $JSON => form => {%export_form} )
  ->status_is( $HTTP_OK, 'the member asks for an export' );
my $export_answer = $client->tx->res->json;
my $answered      = $export_answer->{export_request};
is_deeply(
    [ @{$answered}{qw(export_request_id status)} ],
    [ $pending->{export_request_id}, 'completed' ],
    'which completes their pending export'
);
is( $answered->{manifest}{profile}{email},
    $EMAIL, 'and answers its bundle as an object' );
$client->post_ok( '/privacy/export' => $JSON => form => {%export_form} )
  ->status_is($HTTP_OK)
  ->json_is(
    '/export_request/export_request_id' => $pending->{export_request_id},
    'the same command id replays the export'
  );

# The application's own connection goes before the database is dropped.
my $app_schema = $client->app->gp_schema;
$app_schema->storage->disconnect;
$database->schema->storage->disconnect;

done_testing();

# A member with a password and one post, so the export has something in it.
sub _member {
    my $hash = GPForum::Service::Password->new->hash_password($PASSWORD);
    my ($id) =
      $dbh->selectrow_array( $MEMBER_SQL, undef, $MEMBER, $EMAIL, $hash );
    $dbh->do( $CREDENTIAL_SQL, undef, $id, $hash );
    my ($post) = $dbh->selectrow_array( $POST_SQL, undef, $id );
    $dbh->do( $BODY_SQL, undef, $post );

    return $id;
}

sub _signed_in {
    my $test_object = Test::Mojo->new('GPForum');
    $test_object->get_ok('/login');
    my $form = $test_object->tx->res->dom;
    $test_object->post_ok(
        '/login' => form => {
            command_id => $form->at('input[name=command_id]')->attr('value'),
            csrf_token => $form->at('input[name=csrf_token]')->attr('value'),
            identifier => $MEMBER,
            password   => $PASSWORD,
        }
    );
    $test_object->get_ok('/settings')
      ->status_is( $HTTP_OK, 'the member signs in' );

    return $test_object;
}

1;
