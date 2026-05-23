package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::AllowPermissionGate;
use GPForum::Test::DenyPermissionGate;
use GPForum::Test::ForumWebServices;

our $VERSION = '0.001';

const my $EXPECTED_TESTS    => 68;
const my $HTTP_OK           => 200;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_NOT_FOUND    => 404;

plan tests => $EXPECTED_TESTS;

my $test = Test::Mojo->new('GPForum');
_install_moderation_fakes($test);
_install_test_session_route($test);

_get_json_ok( $test, '/moderation/reports' );
$test->status_is($HTTP_UNAUTHORIZED);

$test->get_ok('/__test/session/moderator-1');
$test->status_is($HTTP_OK);

_get_json_ok( $test, '/moderation/reports' );
$test->status_is($HTTP_OK);
$test->json_is( '/reports/0/report_id'   => 'report-1' );
$test->json_is( '/reports/0/target_type' => 'post' );
$test->json_is( '/status'                => 'open' );
my $csrf_token = _json_value( $test, 'csrf_token' );

$test->get_ok('/moderation/reports');
$test->status_is($HTTP_OK);
$test->element_exists(q{ol[aria-label="Moderation report queue"]});
$test->element_exists(q{form[action="/moderation/posts/post-1/hide"]});

$test->post_ok('/moderation/posts/post-1/hide');
$test->status_is($HTTP_FORBIDDEN);

$test->post_ok(
    '/moderation/posts/post-1/hide' => { Accept => 'application/json' } =>
      form => {
        csrf_token => $csrf_token,
        reason     => q{},
      }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/reason' => 'reason is required' );

$test->post_ok(
    '/moderation/posts/post-1/hide' => { Accept => 'application/json' } =>
      form => {
        csrf_token => $csrf_token,
        reason     => 'spam',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/action/action_type' => 'post.hidden' );

$test->post_ok(
    '/moderation/posts/post-1/restore' => { Accept => 'application/json' } =>
      form => {
        csrf_token => $csrf_token,
        reason     => 'appeal accepted',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/action/action_type' => 'post.restored' );

$test->post_ok(
    '/moderation/threads/thread-1/lock' => { Accept => 'application/json' } =>
      form => {
        csrf_token => $csrf_token,
        reason     => 'heated discussion',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/action/action_type' => 'thread.locked' );

$test->post_ok(
    '/moderation/threads/thread-1/unlock' =>
      { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
        reason     => 'cooled down',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/action/action_type' => 'thread.unlocked' );

$test->post_ok(
    '/moderation/actions/action-post-hide/reverse' =>
      { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/action/reversed_by_user_id' => 'moderator-1' );

$test->post_ok('/moderation/users/user-2/suspend');
$test->status_is($HTTP_FORBIDDEN);

$test->post_ok(
    '/moderation/users/user-2/suspend' => { Accept => 'application/json' } =>
      form => {
        csrf_token => $csrf_token,
        reason     => q{},
      }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/reason' => 'reason is required' );

$test->post_ok(
    '/moderation/users/user-2/suspend' => { Accept => 'application/json' } =>
      form => {
        csrf_token => $csrf_token,
        reason     => 'abuse campaign',
        valid_to   => '2026-05-24T12:00:00Z',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'              => 'user_suspended' );
$test->json_is( '/suspension/user_id'  => 'user-2' );
$test->json_is( '/suspension/valid_to' => '2026-05-24T12:00:00Z' );

$test->post_ok(
    '/moderation/suspensions/suspension-1/revoke' =>
      { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                => 'suspension_revoked' );
$test->json_is( '/suspension/revoked_at' => '2026-05-23T12:00:00Z' );

$test->post_ok(
    '/moderation/users/missing/suspend' => { Accept => 'application/json' } =>
      form => {
        csrf_token => $csrf_token,
        reason     => 'missing user',
      }
);
$test->status_is($HTTP_NOT_FOUND);

$test->post_ok(
    '/moderation/posts/missing/restore' => { Accept => 'application/json' } =>
      form => {
        csrf_token => $csrf_token,
        reason     => 'missing target',
      }
);
$test->status_is($HTTP_NOT_FOUND);

$test->post_ok('/moderation/reports/report-1/assign');
$test->status_is($HTTP_FORBIDDEN);

$test->post_ok(
    '/moderation/reports/report-1/assign' =>
      { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                            => 'assigned' );
$test->json_is( '/report/assigned_moderator_user_id' => 'moderator-1' );

$test->post_ok(
    '/moderation/reports/report-1/resolve' =>
      { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
        resolution => q{},
      }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/resolution' => 'resolution is required' );

$test->post_ok(
    '/moderation/reports/report-1/resolve' =>
      { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
        resolution => 'content_hidden',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'            => 'resolved' );
$test->json_is( '/report/resolution' => 'content_hidden' );

$test->post_ok(
    '/moderation/reports/missing/assign' => { Accept => 'application/json' } =>
      form => {
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_NOT_FOUND);

$test->app->helper(
    gp_permission_gate => sub {
        return GPForum::Test::DenyPermissionGate->new;
    }
);
_get_json_ok( $test, '/moderation/reports' );
$test->status_is($HTTP_FORBIDDEN);

sub _install_moderation_fakes {
    my ($test_object) = @_;

    my $services = GPForum::Test::ForumWebServices->new;
    $test_object->app->helper( gp_report_store => sub { return $services; } );
    $test_object->app->helper(
        gp_moderation_action_store => sub { return $services; } );
    $test_object->app->helper(
        gp_suspension_store => sub { return $services; } );
    $test_object->app->helper(
        gp_permission_gate => sub {
            return GPForum::Test::AllowPermissionGate->new;
        }
    );

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
