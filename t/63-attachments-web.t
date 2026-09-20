package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::AttachmentWebServices;
use GPForum::Test::CommandIdempotency;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_CREATED      => 201;
const my $HTTP_FOUND        => 302;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_NOT_FOUND    => 404;
const my $PNG_BYTES         => "\x89PNG\x0d\x0a\x1a\x0a";

my $test     = Test::Mojo->new('GPForum');
my $services = GPForum::Test::AttachmentWebServices->new;
_install_attachment_fakes( $test, $services );
_install_test_routes($test);

$test->get_ok('/attachments/attachment-1/download');
$test->status_is($HTTP_OK);
$test->content_is($PNG_BYTES);
$test->header_is( 'Content-Type' => 'image/png' );

_get_json_ok( $test, '/attachments/missing/download' );
$test->status_is($HTTP_NOT_FOUND);
$test->json_is( '/status' => 'not_found' );

_get_json_ok( $test, '/attachments/hidden/download' );
$test->status_is($HTTP_FORBIDDEN);
$test->json_is( '/status' => 'forbidden' );

$test->post_ok(
    '/p/post-1/attachments' => { Accept => 'application/json' } => form => {} );
$test->status_is($HTTP_FORBIDDEN);

$test->get_ok('/__test/session/user-2');
$test->status_is($HTTP_OK);
my $csrf_token = _csrf_token($test);
$test->post_ok(
    '/p/post-1/attachments' => { Accept => 'application/json' } => form => {
        command_id => 'upload-forbidden-1',
        csrf_token => $csrf_token,
        attachment => {
            content      => $PNG_BYTES,
            filename     => 'photo.png',
            content_type => 'image/png',
        },
    }
);
$test->status_is($HTTP_FORBIDDEN);
$test->json_is( '/error' => 'post author required' );

$test->get_ok('/__test/session/user-1');
$test->status_is($HTTP_OK);
$csrf_token = _csrf_token($test);
$test->post_ok(
    '/p/post-1/attachments' => { Accept => 'application/json' } => form => {
        command_id => 'upload-invalid-1',
        csrf_token => $csrf_token,
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/attachment' => 'attachment is required' );
$services->upload_calls( [] );

$test->post_ok(
    '/p/post-1/attachments' => { Accept => 'application/json' } => form => {
        command_id => 'upload-json-1',
        csrf_token => $csrf_token,
        attachment => {
            content      => $PNG_BYTES,
            filename     => 'photo.png',
            content_type => 'image/png',
        },
    }
);
$test->status_is($HTTP_CREATED);
$test->json_is( '/status' => 'uploaded' );
$test->json_is(
    '/attachment/download_url' => '/attachments/attachment-1/download' );
$test->json_is( '/attachment/state' => 'available' );
$test->json_is( '/link/target_id'   => 'post-1' );
is( scalar @{ $services->upload_calls },
    1, 'authorized upload calls attachment pipeline once' );

$test->post_ok(
    '/p/post-1/attachments' => form => {
        command_id => 'upload-html-1',
        csrf_token => $csrf_token,
        attachment => {
            content      => $PNG_BYTES,
            filename     => 'photo.png',
            content_type => 'image/png',
        },
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-1\#post-post-1\z}msx );
$test->get_ok('/login');
$test->status_is($HTTP_OK);
$test->content_like(qr/Attachment uploaded/ms);

$test->get_ok('/__test/session/user-2');
$test->status_is($HTTP_OK);
$csrf_token = _csrf_token($test);
$test->post_ok(
    '/p/post-1/attachments/attachment-1/delete' =>
      { Accept => 'application/json' } => form => {
        command_id => 'delete-forbidden-1',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_FORBIDDEN);
$test->json_is( '/error' => 'post author required' );

$test->get_ok('/__test/session/user-1');
$test->status_is($HTTP_OK);
$csrf_token = _csrf_token($test);
$test->post_ok(
    '/p/post-1/attachments/missing/delete' =>
      { Accept => 'application/json' } => form => {
        command_id => 'delete-missing-1',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_NOT_FOUND);
$test->json_is( '/status' => 'not_found' );

$test->post_ok(
    '/p/post-1/attachments/attachment-1/delete' =>
      { Accept => 'application/json' } => form => {
        command_id => 'delete-json-1',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                   => 'deleted' );
$test->json_is( '/attachment/attachment_id' => 'attachment-1' );
$test->json_is( '/attachment/state'         => 'deleted' );

$test->post_ok(
    '/p/post-1/attachments/attachment-1/delete' => form => {
        command_id => 'delete-html-1',
        csrf_token => $csrf_token,
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-1\#post-post-1\z}msx );
$test->get_ok('/login');
$test->status_is($HTTP_OK);
$test->content_like(qr/Attachment deleted/ms);

done_testing();

sub _install_attachment_fakes {
    my ( $test_object, $fake_services ) = @_;

    $test_object->app->helper(
        gp_attachment_delivery => sub { return $fake_services; } );
    $test_object->app->helper(
        gp_attachment_upload_pipeline => sub { return $fake_services; } );
    $test_object->app->helper(
        gp_post_reader => sub { return $fake_services; } );
    $test_object->app->helper(
        gp_attachment_store => sub { return $fake_services; } );
    $test_object->app->helper(
        gp_rate_limiter => sub { return $fake_services; } );
    $test_object->app->helper(
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
        }
    );

    return;
}

sub _get_json_ok {
    my ( $test_object, $path ) = @_;

    return $test_object->get_ok( $path => { Accept => 'application/json' } );
}

sub _install_test_routes {
    my ($test_object) = @_;

    my $routes        = $test_object->app->routes;
    my $session_route = $routes->get('/__test/session/:user_id');
    $session_route->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( json => { ok => 1 } );
        }
    );
    my $csrf_route = $routes->get('/__test/csrf');
    $csrf_route->to(
        cb => sub {
            my ($controller) = @_;

            return $controller->render(
                json => { csrf_token => $controller->csrf_token } );
        }
    );

    return;
}

sub _csrf_token {
    my ($test_object) = @_;

    _get_json_ok( $test_object, '/__test/csrf' );
    $test_object->status_is($HTTP_OK);

    return $test_object->tx->res->json->{csrf_token};
}

1;
