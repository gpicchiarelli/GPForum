# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Operations::CommandIdempotency;
use GPForum::Service::Privacy::Workflow;
use GPForum::Test::AllowLimiter;
use GPForum::Test::AllowPermissionGate;
use GPForum::Test::DenyLimiter;
use GPForum::Test::DenyPermissionGate;
use GPForum::Test::PrivacyWebServices;
use GPForum::Test::Schema;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_FOUND        => 302;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_NOT_FOUND    => 404;
const my $HTTP_CONFLICT     => 409;
const my $HTTP_TOO_MANY     => 429;
const my $FIRST_EXPORT_ROWS => 2;

# The double's rows. Their ids are uuids: a privacy route answers 404 for a
# path id that is not one before anything reads it.
const my %ID => map { $_ => GPForum::Test::PrivacyWebServices->privacy_id($_) }
  qw(deletion export held_job job missing);

my $test     = Test::Mojo->new('GPForum');
my $services = GPForum::Test::PrivacyWebServices->new;
_install_privacy_fakes( $test, $services );
_install_test_session_route($test);

_get_json_ok( $test, '/privacy' );
$test->status_is($HTTP_UNAUTHORIZED);
$test->get_ok("/privacy/export/$ID{export}");
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
$test->element_exists(
    q{form[action="/privacy/export"] input[name="command_id"]});
$test->element_exists(q{form[action="/privacy/deletion"] textarea[required]});

# Asking for an account to be erased is not one press beside "Request
# export": it opens a sheet that says what will happen, and its button is the
# destructive one.
$test->element_exists('button[popovertarget="privacy-deletion"]');
$test->element_exists(
q{#privacy-deletion.sheet[popover] form[action="/privacy/deletion"] button.button--danger}
);
$test->element_exists('#privacy-deletion .sheet__consequence');
$test->element_exists(
    q{form[action="/privacy/deletion"] input[name="command_id"]});
$test->element_exists(qq{a[href="/privacy/export/$ID{export}"]});
$test->content_like(qr/Download export/ms);

$test->get_ok("/privacy/export/$ID{export}");
$test->status_is($HTTP_OK);
$test->header_like( 'Content-Disposition' =>
      qr/attachment; [ ] filename="gpforum-export-\Q$ID{export}\E[.]json"/msx );
$test->json_is( '/posts/0/body_source' => 'Hello' );
$test->json_is( '/profile/email'       => 'giacomo@example.test' );
$test->get_ok("/privacy/export/$ID{missing}");
$test->status_is($HTTP_NOT_FOUND);

$test->get_ok( '/privacy' => { 'Accept-Language' => 'it' } );
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'I tuoi dati' );
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
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/command_id' => 'command_id is required' );

$test->post_ok(
    '/privacy/export' => { Accept => 'application/json' } => form => {
        command_id => 'export-command-1',
        csrf_token => $csrf_token,
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                               => 'export_requested' );
$test->json_is( '/export_request/status'                => 'completed' );
$test->json_is( '/export_request/manifest/counts/posts' => 2 );

$test->post_ok(
    '/privacy/export' => { Accept => 'application/json' } => form => {
        command_id => 'export-command-1',
        csrf_token => $csrf_token,
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/export_request/export_request_id' => 'export-created' );
is( scalar @{ $services->created_export_requests },
    $FIRST_EXPORT_ROWS,
    'repeated export command_id does not create another bundle' );

$test->post_ok(
    '/privacy/export' => form => {
        command_id => 'html-export-command-1',
        csrf_token => $csrf_token,
    }
);
$test->status_is($HTTP_FOUND);
$test->header_is( Location => '/privacy' );
$test->get_ok('/privacy');
$test->status_is($HTTP_OK);
$test->content_like(qr/Export requested/ms);

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
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/command_id' => 'command_id is required' );

$test->post_ok(
    '/privacy/deletion' => { Accept => 'application/json' } => form => {
        command_id => 'deletion-command-1',
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
$test->json_is( '/deletion_requests/0/deletion_request_id' => $ID{deletion} );
$test->json_is( '/erasure_jobs/0/erasure_job_id'           => $ID{job} );

$test->get_ok('/admin/privacy');
$test->status_is($HTTP_OK);
$test->element_exists(
    qq{form[action="/admin/privacy/deletions/$ID{deletion}/approve"]});
$test->element_exists(
qq{form[action="/admin/privacy/deletions/$ID{deletion}/approve"] input[name="command_id"]}
);
$test->element_exists(
    qq{form[action="/admin/privacy/deletions/$ID{deletion}/hold"]});
$test->element_exists(
qq{form[action="/admin/privacy/deletions/$ID{deletion}/hold"] input[name="command_id"]}
);
$test->element_exists(qq{form[action="/admin/privacy/erasure/$ID{job}/run"]});
$test->element_exists(
qq{form[action="/admin/privacy/erasure/$ID{job}/run"] input[name="command_id"]}
);

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
    "/admin/privacy/deletions/$ID{deletion}/approve" =>
      { Accept => 'application/json' } => form => {
        confirm    => 1,
        csrf_token => $csrf_token,
        reason     => q{},
      }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/reason' => 'reason is required' );

$test->post_ok(
    "/admin/privacy/deletions/$ID{deletion}/approve" =>
      { Accept => 'application/json' } => form => {
        confirm    => 1,
        csrf_token => $csrf_token,
        reason     => 'verified identity and no hold',
      }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/command_id' => 'command_id is required' );

$test->post_ok(
    "/admin/privacy/deletions/$ID{deletion}/approve" =>
      { Accept => 'application/json' } => form => {
        confirm    => 1,
        command_id => 'approve-command-1',
        csrf_token => $csrf_token,
        reason     => 'verified identity and no hold',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                             => 'deletion_approved' );
$test->json_is( '/deletion_review/job/erasure_job_id' => 'job-approved' );

$test->post_ok(
    "/admin/privacy/deletions/$ID{deletion}/hold" =>
      { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
        reason     => 'legal hold',
      }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/command_id' => 'command_id is required' );

$test->post_ok(
    "/admin/privacy/deletions/$ID{deletion}/hold" =>
      { Accept => 'application/json' } => form => {
        command_id => 'hold-command-1',
        csrf_token => $csrf_token,
        reason     => 'legal hold',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'             => 'deletion_held' );
$test->json_is( '/deletion_review/ok' => 1 );

$test->post_ok(
    "/admin/privacy/erasure/$ID{held_job}/run" =>
      { Accept => 'application/json' } => form => {
        confirm    => 1,
        command_id => 'erasure-held-command-1',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_CONFLICT);
$test->json_is( '/status' => 'blocked' );
$test->json_is( '/error'  => 'retention_hold_active' );

# Erasure cannot be undone: without the confirmation, nothing runs.
$test->post_ok(
    "/admin/privacy/erasure/$ID{job}/run" =>
      { Accept => 'application/json' } => form => {
        command_id => 'erasure-unconfirmed',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_like( '/errors/confirm' => qr/Confirm/msx );

$test->post_ok(
    "/admin/privacy/erasure/$ID{job}/run" =>
      { Accept => 'application/json' } => form => {
        confirm    => 1,
        command_id => 'erasure-command-1',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'                         => 'erasure_completed' );
$test->json_is( '/erasure_job/action/action_type' => 'anonymized' );

_malformed_ids_are_not_found( $test, $services, $csrf_token );
_refused_writes_are_answered( $test, $csrf_token );

$test->app->helper(
    gp_rate_limiter => sub { return GPForum::Test::DenyLimiter->new; } );
$test->post_ok(
    '/privacy/export' => { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
    }
);
$test->status_is($HTTP_TOO_MANY);

done_testing();

sub _install_privacy_fakes {
    my ( $test_object, $fake_services ) = @_;

    my $workflow = GPForum::Service::Privacy::Workflow->new(
        command_idempotency =>
          GPForum::Service::Operations::CommandIdempotency->new(
            schema => GPForum::Test::Schema->new,
          ),
        deletion_workflow => $fake_services,
        export_builder    => $fake_services,
        hold_store        => $fake_services,
        logger            => $test_object->app->log,
        reviewer          => $fake_services,
    );
    $test_object->app->helper(
        gp_privacy_workflow => sub { return $workflow; } );
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
    $test_object->app->helper(
        gp_rate_limiter => sub { return GPForum::Test::AllowLimiter->new; } );

    return;
}

# A path id that is not a uuid names no row, and PostgreSQL refuses a query
# binding one: the export download answered 500 and the staff review routes
# 503. Now each answers 404 before the permission gate, the reader or the
# workflow is asked; any of them being asked would die here and answer 500.
sub _malformed_ids_are_not_found {
    my ( $test_object, $fake_services, $csrf ) = @_;

    my $app = $test_object->app;
    for my $helper (
        qw(gp_data_rights_review gp_permission_gate gp_privacy_workflow))
    {
        $app->helper(
            $helper => sub { die "a malformed id reached $helper\n"; } );
    }

    $test_object->get_ok('/privacy/export/export-own-1');
    $test_object->status_is( $HTTP_NOT_FOUND,
        'a malformed export id is not found' );

    # Word for word the workflow's error for a missing row: "request not
    # found" and "job not found" were a second answer for the same 404.
    my %error = (
        '/admin/privacy/deletions/delete-1/approve' =>
          'deletion request not found',
        '/admin/privacy/deletions/delete-1/hold' =>
          'deletion request not found',
        '/admin/privacy/erasure/job-1/run' => 'erasure job not found',
    );
    for my $path ( sort keys %error ) {
        $test_object->post_ok(
            $path => { Accept => 'application/json' } => form => {
                command_id => "malformed-$path",
                confirm    => 1,
                csrf_token => $csrf,
                reason     => 'malformed id',
            }
        );
        $test_object->status_is( $HTTP_NOT_FOUND, "$path is not found" );
        $test_object->json_is( '/status' => 'not_found' );
        $test_object->json_is(
            '/error' => $error{$path},
            "$path names the row as the workflow does"
        );
    }

    _install_privacy_fakes( $test_object, $fake_services );

    return;
}

# A refused privacy write returned an empty list into the rate-limit check,
# which died on its signature after the refusal was rendered: the client got
# no response at all instead of the 401 or the 403.
sub _refused_writes_are_answered {
    my ( $test_object, $csrf ) = @_;

    my $anonymous = Test::Mojo->new( $test_object->app );
    $anonymous->get_ok('/login');
    my $login = $anonymous->tx->res->dom;
    my $token = $login->at('input[name=csrf_token]')->attr('value');
    $anonymous->post_ok(
        '/privacy/export' => { Accept => 'application/json' } => form => {
            command_id => 'anonymous-export-1',
            csrf_token => $token,
        }
    );
    $anonymous->status_is( $HTTP_UNAUTHORIZED,
        'a signed-out export request is answered 401' );

    # The session is asked before the id's shape, as on the moderation routes.
    $anonymous->get_ok(
        '/privacy/export/export-own-1' => { Accept => 'application/json' } );
    $anonymous->status_is( $HTTP_UNAUTHORIZED,
        'signed out, a malformed export id is 401 rather than 404' );
    $anonymous->post_ok(
        '/admin/privacy/erasure/job-1/run' =>
          { Accept => 'application/json' } => form => {
            command_id => 'anonymous-erasure-1',
            confirm    => 1,
            csrf_token => $token,
          }
    );
    $anonymous->status_is( $HTTP_UNAUTHORIZED,
        'and so is a malformed erasure job id' );

    $test_object->app->helper(
        gp_permission_gate => sub {
            return GPForum::Test::DenyPermissionGate->new;
        }
    );
    $test_object->post_ok(
        "/admin/privacy/deletions/$ID{deletion}/approve" =>
          { Accept => 'application/json' } => form => {
            command_id => 'forbidden-approve-1',
            confirm    => 1,
            csrf_token => $csrf,
            reason     => 'not mine to approve',
          }
    );
    $test_object->status_is( $HTTP_FORBIDDEN,
        'a forbidden deletion approval is answered 403' );
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
