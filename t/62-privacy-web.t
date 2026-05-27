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
use GPForum::Test::PrivacyWebServices;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_CONFLICT     => 409;

my $test     = Test::Mojo->new('GPForum');
my $services = GPForum::Test::PrivacyWebServices->new;
_install_privacy_fakes( $test, $services );
_install_test_session_route($test);

_get_json_ok( $test, '/privacy' );
$test->status_is($HTTP_UNAUTHORIZED);

$test->get_ok('/__test/session/user-1');
$test->status_is($HTTP_OK);

_get_json_ok( $test, '/privacy' );
$test->status_is($HTTP_OK);
$test->json_is( '/export_requests/0/status' => 'completed' );
$test->json_is( '/export_requests/0/manifest/counts/notifications' => 1 );
$test->json_is( '/deletion_requests/0/status' => 'pending' );
my $csrf_token = _json_value( $test, 'csrf_token' );

$test->get_ok('/privacy');
$test->status_is($HTTP_OK);
$test->element_exists(q{a[href="/privacy"]});
$test->element_exists(q{form[action="/privacy/export"]});
$test->element_exists(q{form[action="/privacy/deletion"] textarea[required]});

$test->get_ok( '/privacy' => { 'Accept-Language' => 'it' } );
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Privacy' );
$test->content_like(qr/Export [ ] dati/msx);
$test->content_like(qr/Richiedi [ ] cancellazione/msx);

$test->post_ok(
    '/privacy/export' => { Accept => 'application/json' } => form => {} );
$test->status_is($HTTP_FORBIDDEN);

$test->post_ok(
    '/privacy/export' => { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                               => 'export_requested' );
$test->json_is( '/export_request/status'                => 'completed' );
$test->json_is( '/export_request/manifest/counts/posts' => 2 );

$test->post_ok(
    '/privacy/deletion' => { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
        reason     => q{},
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/reason' => 'reason is required' );

$test->post_ok(
    '/privacy/deletion' => { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
        reason     => 'Please anonymize my account',
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                             => 'deletion_requested' );
$test->json_is( '/deletion_request/resource_id'       => 'user-1' );
$test->json_is( '/deletion_request/requester_user_id' => 'user-1' );

_get_json_ok( $test, '/admin/privacy' );
$test->status_is($HTTP_OK);
$test->json_is( '/deletion_requests/0/deletion_request_id' => 'delete-1' );
$test->json_is( '/erasure_jobs/0/erasure_job_id'           => 'job-1' );

$test->get_ok('/admin/privacy');
$test->status_is($HTTP_OK);
$test->element_exists(
    q{form[action="/admin/privacy/deletions/delete-1/approve"]});
$test->element_exists(q{form[action="/admin/privacy/deletions/delete-1/hold"]});
$test->element_exists(q{form[action="/admin/privacy/erasure/job-1/run"]});

$test->get_ok( '/admin/privacy' => { 'Accept-Language' => 'it' } );
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Revisione privacy' );
$test->content_like(qr/Richieste [ ] cancellazione/msx);
$test->content_like(qr/Applica [ ] hold/msx);

$test->app->helper(
    gp_permission_gate => sub {
        return GPForum::Test::DenyPermissionGate->new;
    }
);
_get_json_ok( $test, '/admin/privacy' );
$test->status_is($HTTP_FORBIDDEN);

$test->app->helper(
    gp_permission_gate => sub {
        return GPForum::Test::AllowPermissionGate->new;
    }
);
$test->post_ok(
    '/admin/privacy/deletions/delete-1/approve' =>
      { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
        reason     => q{},
      }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/reason' => 'reason is required' );

$test->post_ok(
    '/admin/privacy/deletions/delete-1/approve' =>
      { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
        reason     => 'verified identity and no hold',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                             => 'deletion_approved' );
$test->json_is( '/deletion_review/job/erasure_job_id' => 'job-approved' );

$test->post_ok(
    '/admin/privacy/deletions/delete-1/hold' =>
      { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
        reason     => 'legal hold',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'             => 'deletion_held' );
$test->json_is( '/deletion_review/ok' => 1 );

$test->post_ok(
    '/admin/privacy/erasure/job-held/run' =>
      { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_CONFLICT);
$test->json_is( '/status' => 'blocked' );
$test->json_is( '/error'  => 'retention_hold_active' );

$test->post_ok(
    '/admin/privacy/erasure/job-1/run' => { Accept => 'application/json' } =>
      form => {
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                         => 'erasure_completed' );
$test->json_is( '/erasure_job/action/action_type' => 'anonymized' );

done_testing();

sub _install_privacy_fakes {
    my ( $test_object, $fake_services ) = @_;

    $test_object->app->helper(
        gp_data_rights_review => sub { return $fake_services; } );
    $test_object->app->helper(
        gp_deletion_workflow => sub { return $fake_services; } );
    $test_object->app->helper(
        gp_export_bundle_builder => sub { return $fake_services; } );
    $test_object->app->helper(
        gp_retention_hold_store => sub { return $fake_services; } );
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
