package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::AllowPermissionGate;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::DenyLimiter;
use GPForum::Test::DenyPermissionGate;
use GPForum::Test::ForumWebServices;
use GPForum::Test::IdentityStore;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_FOUND        => 302;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_NOT_FOUND    => 404;
const my $HTTP_TOO_MANY     => 429;

my $test     = Test::Mojo->new('GPForum');
my $services = _install_moderation_fakes($test);
_install_test_session_route($test);

_get_json_ok( $test, '/moderation/reports' );
$test->status_is($HTTP_UNAUTHORIZED);

$test->get_ok('/__test/session/moderator-1');
$test->status_is($HTTP_OK);

_get_json_ok( $test, '/moderation/reports' );
$test->status_is($HTTP_OK);
$test->json_is( '/reports/0/report_id'   => 'report-1' );
$test->json_is( '/reports/0/target_type' => 'post' );
$test->json_is(
    '/reports/0/ui/post_reason_id' => 'report-report-1-post-reason' );
$test->json_is( '/status' => 'open' );
my $csrf_token = _json_value( $test, 'csrf_token' );

$test->get_ok('/moderation/reports');
$test->status_is($HTTP_OK);
$test->element_exists(q{ol[aria-label="Moderation report queue"]});
$test->element_exists(q{form[action="/moderation/posts/post-1/hide"]});
$test->element_exists(
    q{form[action="/moderation/posts/post-1/hide"] input[name="command_id"]});
$test->element_exists(q{form[action="/moderation/reports/report-1/assign"]});
$test->element_exists(
q{form[action="/moderation/reports/report-1/assign"] input[name="command_id"]}
);
$test->element_exists(q{form[action="/moderation/reports/report-1/release"]});
$test->element_exists(
q{form[action="/moderation/reports/report-1/release"] input[name="command_id"]}
);
$test->element_exists(q{form[action="/moderation/reports/report-1/resolve"]});
$test->element_exists(
q{form[action="/moderation/reports/report-1/resolve"] input[name="command_id"]}
);

$test->get_ok( '/moderation/reports' => { 'Accept-Language' => 'it' } );
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Segnalazioni moderazione' );
$test->content_like(qr/Aperto/msx);
$test->content_like(qr/Nascondi [ ] post/msx);
$test->content_like(qr/Assegna [ ] a [ ] me/msx);

_get_json_ok( $test, '/moderation/actions' );
$test->status_is($HTTP_OK);
$test->json_is( '/actions/0/moderation_action_id' => 'action-post-hide' );
$test->json_is( '/actions/0/action_type'          => 'post.hidden' );
$test->json_is( '/actions/0/ui/reverse_reason_id' =>
      'action-action-post-hide-reverse-reason' );
$test->json_is( '/next_cursor' => 'action-cursor' );

$test->get_ok('/moderation/actions');
$test->status_is($HTTP_OK);
$test->element_exists(q{ol[aria-label="Moderation action history"]});
$test->element_exists(q{form[action="/moderation/posts/post-1/restore"]});
$test->element_exists(
    q{form[action="/moderation/posts/post-1/restore"] input[name="command_id"]}
);
$test->element_exists(
    q{form[action="/moderation/actions/action-post-hide/reverse"]});
$test->element_exists(
q{form[action="/moderation/actions/action-post-hide/reverse"] input[name="command_id"]}
);

_get_json_ok( $test, '/moderation/suspensions' );
$test->status_is($HTTP_OK);
$test->json_is( '/suspensions/0/suspension_id' => 'suspension-1' );
$test->json_is( '/suspensions/0/user_id'       => 'user-2' );
$test->json_is( '/suspensions/0/ui/revoke_reason_id' =>
      'suspension-suspension-1-revoke-reason' );
$test->json_has('/suspensions/0/revoke_command_id');
$test->json_is( '/next_cursor' => 'suspension-cursor' );

$test->get_ok('/moderation/suspensions');
$test->status_is($HTTP_OK);
$test->element_exists(q{ol[aria-label="Active suspension list"]});
$test->element_exists(
q{form[action="/moderation/suspensions/suspension-1/revoke"] input[name="command_id"]}
);

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
        command_id => 'hide-command-1',
        csrf_token => $csrf_token,
        reason     => 'spam',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/action/action_type' => 'post.hidden' );
is( $services->last_moderation_input->{command_id},
    'hide-command-1', 'hide_post passes command_id into the action store' );

$test->post_ok(
    '/moderation/posts/post-1/hide' => form => {
        command_id => 'html-hide-command-1',
        csrf_token => $csrf_token,
        reason     => 'spam',
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/moderation/reports\z}msx );
$test->get_ok('/moderation/reports');
$test->status_is($HTTP_OK);
$test->text_is( 'p.flash--success[role="status"]' => 'Post hidden' );

$test->post_ok(
    '/moderation/reports/report-1/assign' => form => {
        command_id => 'html-assign-command-1',
        csrf_token => $csrf_token,
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/moderation/reports\z}msx );
$test->get_ok('/moderation/reports');
$test->status_is($HTTP_OK);
$test->text_is( 'p.flash--success[role="status"]' => 'Report assigned' );

$test->post_ok(
    '/moderation/posts/post-1/restore' => { Accept => 'application/json' } =>
      form => {
        command_id => 'restore-command-1',
        csrf_token => $csrf_token,
        reason     => 'appeal accepted',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/action/action_type' => 'post.restored' );
is( $services->last_moderation_input->{command_id},
    'restore-command-1',
    'restore_post passes command_id into the action store' );

$test->post_ok(
    '/moderation/threads/thread-1/lock' => { Accept => 'application/json' } =>
      form => {
        command_id => 'lock-command-1',
        csrf_token => $csrf_token,
        reason     => 'heated discussion',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/action/action_type' => 'thread.locked' );
is( $services->last_moderation_input->{command_id},
    'lock-command-1', 'lock_thread passes command_id into the action store' );

$test->post_ok(
    '/moderation/threads/thread-1/unlock' =>
      { Accept => 'application/json' } => form => {
        command_id => 'unlock-command-1',
        csrf_token => $csrf_token,
        reason     => 'cooled down',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/action/action_type' => 'thread.unlocked' );
is( $services->last_moderation_input->{command_id},
    'unlock-command-1',
    'unlock_thread passes command_id into the action store' );

$test->post_ok(
    '/moderation/threads/thread-1/hide' => { Accept => 'application/json' } =>
      form => {
        command_id => 'hide-thread-command-1',
        csrf_token => $csrf_token,
        reason     => 'off-topic',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/action/action_type' => 'thread.hidden' );
is( $services->last_moderation_input->{command_id},
    'hide-thread-command-1',
    'hide_thread passes command_id into the action store' );

$test->post_ok(
    '/moderation/threads/thread-1/restore' =>
      { Accept => 'application/json' } => form => {
        command_id => 'restore-thread-command-1',
        csrf_token => $csrf_token,
        reason     => 'cleared',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/action/action_type' => 'thread.restored' );
is( $services->last_moderation_input->{command_id},
    'restore-thread-command-1',
    'restore_thread passes command_id into the action store' );

$test->post_ok(
    '/moderation/actions/action-post-hide/reverse' =>
      { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/command_id' => 'command_id is required' );

$test->post_ok(
    '/moderation/actions/action-post-hide/reverse' =>
      { Accept => 'application/json' } => form => {
        command_id => 'reverse-command-1',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/reason' => 'reason is required' );

$test->post_ok(
    '/moderation/actions/action-post-hide/reverse' =>
      { Accept => 'application/json' } => form => {
        command_id => 'reverse-command-1',
        csrf_token => $csrf_token,
        reason     => 'appeal accepted',
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
        command_id => 'suspend-command-1',
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
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/reason' => 'reason is required' );

$test->post_ok(
    '/moderation/suspensions/suspension-1/revoke' =>
      { Accept => 'application/json' } => form => {
        command_id => 'revoke-command-1',
        csrf_token => $csrf_token,
        reason     => 'appeal accepted',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                => 'suspension_revoked' );
$test->json_is( '/suspension/revoked_at' => '2026-05-23T12:00:00Z' );

$test->post_ok(
    '/moderation/users/missing/suspend' => { Accept => 'application/json' } =>
      form => {
        command_id => 'missing-suspend-command-1',
        csrf_token => $csrf_token,
        reason     => 'missing user',
      }
);
$test->status_is($HTTP_NOT_FOUND);

$test->post_ok(
    '/moderation/posts/missing/restore' => { Accept => 'application/json' } =>
      form => {
        command_id => 'missing-restore-command-1',
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
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/command_id' => 'command_id is required' );

$test->post_ok(
    '/moderation/reports/report-1/assign' =>
      { Accept => 'application/json' } => form => {
        command_id => 'assign-command-1',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                            => 'assigned' );
$test->json_is( '/report/assigned_moderator_user_id' => 'moderator-1' );

$test->post_ok(
    '/moderation/reports/report-1/release' =>
      { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/command_id' => 'command_id is required' );

$test->post_ok(
    '/moderation/reports/report-1/release' =>
      { Accept => 'application/json' } => form => {
        command_id => 'release-command-1',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                            => 'released' );
$test->json_is( '/report/assigned_moderator_user_id' => undef );

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
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/command_id' => 'command_id is required' );

$test->post_ok(
    '/moderation/reports/report-1/resolve' =>
      { Accept => 'application/json' } => form => {
        command_id => 'resolve-command-1',
        csrf_token => $csrf_token,
        resolution => 'content_hidden',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'            => 'resolved' );
$test->json_is( '/report/resolution' => 'content_hidden' );

$test->get_ok('/u/giacomo_forum');
$test->status_is($HTTP_OK);
$test->element_exists(q{form[action="/u/giacomo_forum/report"]});
$test->element_exists(
    q{form[action="/u/giacomo_forum/report"] input[name="command_id"]});

$test->post_ok(
    '/u/giacomo_forum/report' => { Accept => 'application/json' } => form => {
        command_id => 'profile-report-1',
        csrf_token => $csrf_token,
        reason     => 'impersonation',
        details    => 'Profile is pretending to be staff',
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'             => 'reported' );
$test->json_is( '/report/target_type' => 'user' );
$test->json_is( '/report/target_id'   => 'user-1' );
$test->json_is( '/report/details'     => 'Profile is pretending to be staff' );

$test->post_ok(
    '/u/giacomo_forum/report' => { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
        reason     => q{},
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/reason' => 'reason is required' );

$test->post_ok(
    '/u/missing/report' => { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
        reason     => 'missing profile',
    }
);
$test->status_is($HTTP_NOT_FOUND);

$test->post_ok(
    '/moderation/reports/missing/assign' => { Accept => 'application/json' } =>
      form => {
        command_id => 'missing-assign-command-1',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_NOT_FOUND);

$test->app->helper(
    gp_rate_limiter => sub { return GPForum::Test::DenyLimiter->new; } );
$test->post_ok(
    '/moderation/posts/post-1/hide' => { Accept => 'application/json' } =>
      form => {
        csrf_token => $csrf_token,
        reason     => 'too fast',
      }
);
$test->status_is($HTTP_TOO_MANY);

$test->app->helper(
    gp_permission_gate => sub {
        return GPForum::Test::DenyPermissionGate->new;
    }
);
_get_json_ok( $test, '/moderation/reports' );
$test->status_is($HTTP_FORBIDDEN);

done_testing();

sub _install_moderation_fakes {
    my ($test_object) = @_;

    my $fakes = GPForum::Test::ForumWebServices->new;
    $test_object->app->helper(
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
        }
    );
    $test_object->app->helper( gp_report_store => sub { return $fakes; } );
    $test_object->app->helper(
        gp_moderation_action_store => sub { return $fakes; } );
    $test_object->app->helper( gp_suspension_store => sub { return $fakes; } );
    $test_object->app->helper(
        gp_moderation_review_reader => sub { return $fakes; } );
    $test_object->app->helper( gp_rate_limiter => sub { return $fakes; } );
    $test_object->app->helper(
        gp_profile_reader => sub {
            return GPForum::Test::IdentityStore->new;
        }
    );
    $test_object->app->helper(
        gp_permission_gate => sub {
            return GPForum::Test::AllowPermissionGate->new;
        }
    );

    return $fakes;
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
