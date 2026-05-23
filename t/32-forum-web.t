package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::DenyLimiter;
use GPForum::Test::FailReadiness;
use GPForum::Test::ForumWebServices;

our $VERSION = '0.001';

const my $EXPECTED_TESTS       => 82;
const my $HTTP_OK              => 200;
const my $HTTP_CREATED         => 201;
const my $HTTP_UNAUTHORIZED    => 401;
const my $HTTP_FORBIDDEN       => 403;
const my $HTTP_NOT_FOUND       => 404;
const my $HTTP_TOO_MANY        => 429;
const my $HTTP_SERVICE_UNAVAIL => 503;

plan tests => $EXPECTED_TESTS;

my $test = Test::Mojo->new('GPForum');
_install_forum_fakes($test);
_install_test_session_route($test);

_get_json_ok( $test, '/categories' );
$test->status_is($HTTP_OK);
$test->json_is( '/categories/0/category_id' => 'category-1' );

_get_json_ok( $test, '/c/category-1' );
$test->status_is($HTTP_OK);
$test->json_is( '/category/category_id' => 'category-1' );
$test->json_is( '/threads/0/thread_id'  => 'thread-1' );
$test->json_is( '/next_cursor'          => 'thread-cursor' );

_get_json_ok( $test, '/c/missing' );
$test->status_is($HTTP_NOT_FOUND);

_get_json_ok( $test, '/t/thread-1' );
$test->status_is($HTTP_OK);
$test->json_is( '/thread/thread_id' => 'thread-1' );
$test->json_is( '/posts/0/body'     => 'First post' );
$test->json_is( '/next_cursor'      => 'post-cursor' );

_get_json_ok( $test, '/t/missing' );
$test->status_is($HTTP_NOT_FOUND);

_get_json_ok( $test, '/new-thread' );
$test->status_is($HTTP_OK);
$test->json_is( '/fields/0' => 'category_id' );

my $csrf_token = _json_value( $test, 'csrf_token' );

_get_json_ok( $test, '/bookmarks' );
$test->status_is($HTTP_UNAUTHORIZED);
_get_json_ok( $test, '/notifications' );
$test->status_is($HTTP_UNAUTHORIZED);

$test->post_ok('/threads');
$test->status_is($HTTP_FORBIDDEN);

$test->post_ok(
    '/threads' => form => {
        csrf_token  => $csrf_token,
        category_id => 'category-1',
        title       => 'A real thread',
        body_source => 'Opening post',
        visibility  => 'public',
    }
);
$test->status_is($HTTP_UNAUTHORIZED);

$test->get_ok('/__test/session/user-1');
$test->status_is($HTTP_OK);
_get_json_ok( $test, '/new-thread' );
my $session_csrf = _json_value( $test, 'csrf_token' );

$test->post_ok(
    '/threads' => { Accept => 'application/json' } => form => {
        csrf_token  => $session_csrf,
        category_id => 'category-1',
        title       => 'A real thread',
        body_source => 'Opening post',
        visibility  => 'public',
    }
);
$test->status_is($HTTP_CREATED);
$test->json_is( '/thread_id' => 'thread-created' );

$test->post_ok(
    '/t/thread-1/replies' => { Accept => 'application/json' } => form => {
        csrf_token  => $session_csrf,
        body_source => 'A reply',
        visibility  => 'public',
    }
);
$test->status_is($HTTP_CREATED);
$test->json_is( '/post_id' => 'post-created' );

$test->post_ok(
    '/t/thread-1/read' => { Accept => 'application/json' } => form => {
        csrf_token         => $session_csrf,
        last_read_position => 1,
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/read_state/last_read_position' => 1 );

_get_json_ok( $test, '/bookmarks' );
$test->status_is($HTTP_OK);
$test->json_is( '/bookmarks/0/target_id' => 'thread-1' );
$test->json_is( '/next_cursor'           => 'bookmark-cursor' );

_get_json_ok( $test, '/notifications' );
$test->status_is($HTTP_OK);
$test->json_is( '/notifications/0/notification_id' => 'notification-1' );
$test->json_is( '/next_cursor'                     => 'notification-cursor' );

$test->post_ok(
    '/notifications/notification-1/read' => { Accept => 'application/json' } =>
      form => {
        csrf_token => $session_csrf,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'               => 'read' );
$test->json_is( '/read/notification_id' => 'notification-1' );

$test->post_ok(
    '/t/thread-1/bookmark' => { Accept => 'application/json' } => form => {
        csrf_token => $session_csrf,
        note       => 'Read later',
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'             => 'bookmarked' );
$test->json_is( '/bookmark/target_id' => 'thread-1' );

$test->post_ok(
    '/t/thread-1/bookmark/remove' => { Accept => 'application/json' } =>
      form => {
        csrf_token => $session_csrf,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status' => 'bookmark_removed' );

$test->post_ok(
    '/t/thread-1/subscribe' => { Accept => 'application/json' } => form => {
        csrf_token => $session_csrf,
        preference => 'all',
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                  => 'subscribed' );
$test->json_is( '/subscription/preference' => 'all' );
$test->json_is( '/subscription/target_id'  => 'thread-1' );

$test->post_ok(
    '/t/thread-1/subscribe/mute' => { Accept => 'application/json' } => form =>
      {
        csrf_token => $session_csrf,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status' => 'subscription_muted' );

$test->post_ok(
    '/t/thread-1/subscribe/remove' => { Accept => 'application/json' } =>
      form => {
        csrf_token => $session_csrf,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status' => 'unsubscribed' );

_get_json_ok( $test, '/search?q=welcome' );
$test->status_is($HTTP_OK);
$test->json_is( '/results/0/entity_id' => 'thread-1' );

_get_json_ok( $test, '/search' );
$test->status_is($HTTP_OK);
$test->json_is( '/results' => [] );

$test->app->helper(
    gp_rate_limiter => sub { return GPForum::Test::DenyLimiter->new; } );
_get_json_ok( $test, '/new-thread' );
my $rate_csrf = _json_value( $test, 'csrf_token' );
$test->post_ok(
    '/threads' => form => {
        csrf_token  => $rate_csrf,
        category_id => 'category-1',
        title       => 'Too fast',
        body_source => 'Opening post',
        visibility  => 'public',
    }
);
$test->status_is($HTTP_TOO_MANY);

$test->app->helper(
    gp_readiness => sub { return GPForum::Test::FailReadiness->new; } );
$test->get_ok('/health/ready');
$test->status_is($HTTP_SERVICE_UNAVAIL);
$test->json_is( '/status' => 'fail' );

sub _install_forum_fakes {
    my ($test_object) = @_;

    my $services = GPForum::Test::ForumWebServices->new;
    for my $helper (
        qw(
        gp_category_reader gp_thread_reader gp_thread_detail_reader
        gp_thread_composer gp_thread_store gp_post_composer gp_post_store
        gp_post_position gp_thread_read_state gp_mention_store
        gp_bookmark_store gp_subscription_store gp_notification_dispatcher
        gp_search_service gp_rate_limiter
        )
      )
    {
        $test_object->app->helper( $helper => sub { return $services; } );
    }

    return;
}

sub _get_json_ok {
    my ( $test_object, $path ) = @_;

    return $test_object->get_ok( $path => { Accept => 'application/json' } );
}

sub _install_test_session_route {
    my ($test_object) = @_;

    my $routes = $test_object->app->routes;
    my $route  = $routes->get('/__test/session/:user_id');
    $route->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( json => { ok => 1 } );
        }
    );

    return;
}

sub _json_value {
    my ( $test_object, $key ) = @_;

    my $transaction = $test_object->tx;
    my $response    = $transaction->res;
    my $json        = $response->json;

    return $json->{$key};
}

1;
