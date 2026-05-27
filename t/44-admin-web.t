package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::AdminWebServices;
use GPForum::Test::AllowPermissionGate;
use GPForum::Test::DenyPermissionGate;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;

my $test = Test::Mojo->new('GPForum');
_install_admin_fakes($test);
_install_test_session_route($test);

_get_json_ok( $test, '/admin' );
$test->status_is($HTTP_UNAUTHORIZED);

$test->get_ok('/__test/session/admin-1');
$test->status_is($HTTP_OK);

_get_json_ok( $test, '/admin' );
$test->status_is($HTTP_OK);
$test->json_is( '/roles/0/role_id'                           => 'role-1' );
$test->json_is( '/audit_rows/0/audit_id'                     => 'audit-1' );
$test->json_is( '/summary/users/0/id'                        => 'user-1' );
$test->json_is( '/summary/async/outbox_messages/0/outbox_id' => 'outbox-1' );
$test->json_is( '/summary/health/readiness/status'           => 'ok' );
my $csrf_token = _json_value( $test, 'csrf_token' );

$test->get_ok('/admin');
$test->status_is($HTTP_OK);
$test->element_exists(q{nav[aria-label="Admin"] a[href="/admin/users"]});
$test->element_exists(q{nav[aria-label="Admin"] a[href="/admin/jobs"]});
$test->element_exists(q{nav[aria-label="Admin"] a[href="/admin/status"]});
$test->element_exists(q{ol[aria-label="Admin user summary"]});
$test->element_exists(q{ol[aria-label="Admin moderation summary"]});

$test->get_ok( '/admin' => { 'Accept-Language' => 'it' } );
$test->status_is($HTTP_OK);
$test->text_is( 'nav[aria-label="Admin"] a[href="/admin/users"]' => 'Utenti' );
$test->text_is( 'nav[aria-label="Admin"] a[href="/admin/roles"]' => 'Ruoli' );
$test->text_is(
    'nav[aria-label="Admin"] a[href="/admin/jobs"]' => 'Job asincroni' );
$test->content_like(qr/Salute [ ] e [ ] runtime/msx);
$test->content_like(qr/Attivo/msx);

$test->get_ok('/admin/users');
$test->status_is($HTTP_OK);
$test->element_exists(q{ol[aria-label="Admin user list"]});
$test->element_exists(q{a[href="/admin/users/user-1/roles"]});

_get_json_ok( $test, '/admin/users' );
$test->status_is($HTTP_OK);
$test->json_is( '/users/0/username'      => 'admin_user' );
$test->json_is( '/users/0/ui/heading_id' => 'admin-user-user-1-heading' );

$test->get_ok('/admin/jobs');
$test->status_is($HTTP_OK);
$test->element_exists(q{ol[aria-label="Admin outbox list"]});
$test->element_exists(q{ol[aria-label="Admin dead-letter list"]});

_get_json_ok( $test, '/admin/jobs' );
$test->status_is($HTTP_OK);
$test->json_is( '/jobs/outbox_messages/0/job_type' => 'notification.dispatch' );
$test->json_is( '/jobs/dead_letters/0/error_class' => 'worker_failed' );
$test->json_is(
    '/jobs/outbox_messages/0/ui/heading_id' => 'outbox-outbox-1-heading' );

$test->get_ok('/admin/status');
$test->status_is($HTTP_OK);
$test->element_exists(q{ol[aria-label="Admin readiness checks"]});
$test->content_like(qr/script\/benchmark-http [ ] --fixture [ ] --check/msx);

_get_json_ok( $test, '/admin/status' );
$test->status_is($HTTP_OK);
$test->json_is( '/admin_status/readiness/status'          => 'ok' );
$test->json_is( '/admin_status/query_budget_drift/status' => 'ok' );
$test->json_is( '/readiness/status'                       => 'ok' );
$test->json_is( '/query_budget_rows/0/endpoint' => 'admin_dashboard' );

$test->get_ok('/admin/roles');
$test->status_is($HTTP_OK);
$test->element_exists(q{ol[aria-label="Admin role list"]});
$test->element_exists(q{ol[aria-label="Admin permission list"]});
$test->element_exists(q{form[action="/admin/roles"]});

$test->post_ok('/admin/roles');
$test->status_is($HTTP_FORBIDDEN);

$test->post_ok(
    '/admin/roles' => { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
        name       => q{},
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/name' => 'name is required' );

$test->post_ok(
    '/admin/roles' => { Accept => 'application/json' } => form => {
        csrf_token  => $csrf_token,
        description => 'Scoped admin',
        name        => 'space_admin',
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'    => 'role_created' );
$test->json_is( '/role/name' => 'space_admin' );

$test->post_ok(
    '/admin/permissions' => { Accept => 'application/json' } => form => {
        action        => 'view',
        csrf_token    => $csrf_token,
        name          => 'admin_console.view',
        resource_type => 'admin_console',
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                   => 'permission_created' );
$test->json_is( '/permission/resource_type' => 'admin_console' );

$test->post_ok(
    '/admin/roles/role-1/permissions' => { Accept => 'application/json' } =>
      form => {
        csrf_token    => $csrf_token,
        permission_id => q{},
        role_id       => 'role-1',
      }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/permission_id' => 'permission_id is required' );

$test->post_ok(
    '/admin/roles/role-1/permissions' => { Accept => 'application/json' } =>
      form => {
        csrf_token    => $csrf_token,
        permission_id => 'permission-1',
        role_id       => 'role-1',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status' => 'role_permission_attached' );
$test->json_is( '/role_permission/permission_id' => 'permission-1' );

_get_json_ok( $test, '/admin/users/user-2/roles' );
$test->status_is($HTTP_OK);
$test->json_is( '/bindings/0/binding_id' => 'binding-1' );

$test->get_ok('/admin/users/user-2/roles');
$test->status_is($HTTP_OK);
$test->element_exists(q{ol[aria-label="User role bindings"]});
$test->element_exists(q{form[action="/admin/role-bindings/binding-1/revoke"]});

$test->post_ok(
    '/admin/users/user-2/roles' => { Accept => 'application/json' } => form => {
        csrf_token    => $csrf_token,
        resource_type => 'global',
        role_id       => q{},
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/role_id' => 'role_id is required' );

$test->post_ok(
    '/admin/users/user-2/roles' => { Accept => 'application/json' } => form => {
        csrf_token    => $csrf_token,
        resource_type => 'global',
        role_id       => 'role-1',
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'          => 'role_bound' );
$test->json_is( '/binding/role_id' => 'role-1' );

$test->post_ok(
    '/admin/role-bindings/binding-1/revoke' =>
      { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'             => 'role_binding_revoked' );
$test->json_is( '/binding/revoked_at' => '2026-05-23T12:00:00Z' );

_get_json_ok( $test, '/admin/audit' );
$test->status_is($HTTP_OK);
$test->json_is( '/audit_rows/0/audit_id' => 'audit-1' );
$test->json_is(
    '/audit_rows/0/metadata_items/0/value' => 'least privilege review' );

$test->get_ok('/admin/audit');
$test->status_is($HTTP_OK);
$test->element_exists(q{ol[aria-label="Admin audit log"]});
$test->content_like(qr/least [ ] privilege [ ] review/msx);

$test->app->helper(
    gp_permission_gate => sub {
        return GPForum::Test::DenyPermissionGate->new;
    }
);
_get_json_ok( $test, '/admin' );
$test->status_is($HTTP_FORBIDDEN);
_get_json_ok( $test, '/admin/jobs' );
$test->status_is($HTTP_FORBIDDEN);

done_testing();

sub _install_admin_fakes {
    my ($test_object) = @_;

    my $services = GPForum::Test::AdminWebServices->new;
    $test_object->app->helper( gp_role_catalog => sub { return $services; } );
    $test_object->app->helper(
        gp_role_binding_store => sub { return $services; } );
    $test_object->app->helper(
        gp_permission_review => sub { return $services; } );
    $test_object->app->helper(
        gp_admin_audit_review => sub { return $services; } );
    $test_object->app->helper(
        gp_admin_console_reader => sub { return $services; } );
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
