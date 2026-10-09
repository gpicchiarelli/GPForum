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

const my $HTTP_OK          => 200;
const my $HTTP_BAD_REQUEST => 400;
const my $HTTP_NOT_FOUND   => 404;
const my $HTTP_UNAVAILABLE => 503;
const my $PASSWORD         => 'correct horse battery staple';
const my $ADMIN            => 'category_web_admin';
const my $JSON             => { Accept => 'application/json' };
const my $MALFORMED        => 'not-a-uuid';

# Well formed and naming no row: the workflow's own not-found.
const my $UNKNOWN => '018f1006-0000-7000-8000-000000000000';

const my $CATEGORIES_SQL => 'SELECT count(*) FROM categories';
const my $DELETE_SQL =>
  'UPDATE categories SET deleted_at = now() WHERE category_id = ?';
const my $SLUG_SQL => 'SELECT slug FROM categories WHERE category_id = ?';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the admin category'
      . ' web test';
}

# The admin category routes against the application and PostgreSQL. A space
# id in the body or a category id in the path that was not a uuid reached
# CategoryStore, PostgreSQL refused it as a uuid parameter, and the route
# answered 503, as if the database were down, for what is a 404. The store
# now refuses such an id before any statement is sent, and the route answers
# exactly as it does for a well-formed id naming no row.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;

my $database = GPForum::Test::PgDatabase->fresh;
local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;
my $dbh = $database->dbh;

_administrator();
my $client = _signed_in();
my $csrf   = _csrf($client);

my $lounge = _post( '/admin/categories', { title => 'Lounge' } );
$client->status_is( $HTTP_OK, 'a category is created' );
my $staff = _post( '/admin/categories', { title => 'Staff' } );
my $count = _categories();

_post( '/admin/categories', { space_id => $MALFORMED, title => 'Orphan' } );
$client->status_is( $HTTP_NOT_FOUND,
    'a create naming a space id that is not a uuid is 404' )
  ->json_is( '/status' => 'not_found' );
my $malformed_space = $client->tx->res->json;
_post( '/admin/categories', { space_id => $UNKNOWN, title => 'Orphan' } );
$client->status_is( $HTTP_NOT_FOUND, 'as is one naming an unknown space' );
is_deeply( $client->tx->res->json,
    $malformed_space, 'and both answer word for word alike' );

_post( "/admin/categories/$MALFORMED", { title => 'Gone' } );
$client->status_is( $HTTP_NOT_FOUND,
    'an update of a category id that is not a uuid is 404' )
  ->json_is( '/status' => 'not_found' );
my $malformed_category = $client->tx->res->json;
_post( "/admin/categories/$UNKNOWN", { title => 'Gone' } );
$client->status_is( $HTTP_NOT_FOUND, 'as is one of an unknown category' );
is_deeply( $client->tx->res->json,
    $malformed_category, 'and both answer word for word alike' );
is( _categories(), $count, 'none of them writes a category' );

# categories_space_slug_key is not partial: a soft-deleted category keeps its
# slug. Creating its slug again, or moving another category's slug onto a
# taken one, met the key, and the route answered 503.
$dbh->do( $DELETE_SQL, undef, $lounge->{category_id} );
_post( '/admin/categories', { title => 'Lounge' } );
isnt( $client->tx->res->code,
    $HTTP_UNAVAILABLE, 'a soft-deleted category\'s slug is not a 503' );
_post( "/admin/categories/$staff->{category_id}", { slug => $lounge->{slug} } );
isnt( $client->tx->res->code,
    $HTTP_UNAVAILABLE,
    'nor is moving a category onto a soft-deleted one\'s slug' );
is( scalar $dbh->selectrow_array( $SLUG_SQL, undef, $staff->{category_id} ),
    'staff', 'which leaves the slug as it was' );
is( _categories(), $count, 'and adds no category' );

# The store answers that the slug is taken, and Admin::Workflow turns that
# answer into "invalid": both routes answer 400 naming the slug.
_post( '/admin/categories', { title => 'Lounge' } );
_slug_taken('a soft-deleted category\'s slug is taken');
_post( "/admin/categories/$staff->{category_id}", { slug => $lounge->{slug} } );
_slug_taken('as it is to a category moved onto it');

# The application's own connection goes before the database is dropped, or
# its statement handles complain on the way out.
my $app_schema = $client->app->gp_schema;
$app_schema->storage->disconnect;

done_testing();

# Posts $form with a fresh command id and the session's CSRF token, asking for
# JSON; answers the category the response carries.
sub _post {
    my ( $path, $form ) = @_;

    $client->post_ok(
        $path => $JSON => form => {
            command_id => GPForum::Infrastructure::Id->new->uuid,
            csrf_token => $csrf,
            %{$form},
        }
    );
    my $json = $client->tx->res->json // {};

    return $json->{category} // {};
}

# The last response is the workflow's "invalid", naming the slug.
sub _slug_taken {
    my ($name) = @_;

    $client->status_is( $HTTP_BAD_REQUEST, $name )
      ->json_is( '/errors/slug' => 'slug is taken' );

    return;
}

sub _categories {
    return scalar $dbh->selectrow_array($CATEGORIES_SQL);
}

sub _csrf {
    my ($test_object) = @_;

    $test_object->get_ok('/admin/categories')->status_is($HTTP_OK);
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
            identifier => $ADMIN,
            password   => $PASSWORD,
        }
    );
    $test_object->get_ok('/admin/categories')
      ->status_is( $HTTP_OK, 'the administrator signs in' );

    return $test_object;
}

# A user with a password, given the bootstrap administration role.
sub _administrator {
    my $hash = GPForum::Service::Password->new->hash_password($PASSWORD);
    my ($id) = $dbh->selectrow_array(
        q{INSERT INTO users (id, username, display_name, email_normalized,}
          . q{ password_hash, status) VALUES (gen_random_uuid(), ?,}
          . q{ 'Category admin', 'category-admin@example.test', ?,}
          . q{ 'active') RETURNING id},
        undef, $ADMIN, $hash
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
        'the administrator receives the bootstrap role'
    );

    return $id;
}

1;
