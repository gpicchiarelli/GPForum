# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::AllowLimiter;
use GPForum::Test::AllowPermissionGate;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::ForumWebServices;
use GPForum::Test::IdentitySecurityAudit;
use GPForum::Test::IdentityStore;
use GPForum::Test::ScriptedWorkflow;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_CONFLICT     => 409;
const my $HTTP_UNAVAILABLE  => 503;
const my $JSON              => { Accept => 'application/json' };
const my $COMMAND_ID        => '018f1000-0000-7000-8000-0000000000c1';

# Branches the controller collapses folded into their actions, each answered
# as before: a login refused as unverified or failed, and a bookmark write
# that conflicts.

my $identity = GPForum::Test::IdentityStore->new;
my $test     = Test::Mojo->new('GPForum');
$test->app->log->level('fatal');
_install_fakes( $test->app );

subtest 'an unverified member is told to verify, with 401' => sub {
    $identity->unverified_login(1);
    _login_ok();
    $test->status_is($HTTP_UNAUTHORIZED);
    $test->content_like(
        qr/Verify [ ] your [ ] email [ ] before [ ] signing/msx);
    $identity->unverified_login(0);
};

subtest 'a login the identity store cannot answer is unavailable' => sub {
    my $failed = GPForum::Test::ScriptedWorkflow->new(
        answer => { ok => 0, status => 'failed', error => 'store failed' } );
    my $live = $test->app->renderer->get_helper('gp_identity_workflow');
    $test->app->helper( gp_identity_workflow => sub { return $failed; } );
    _login_ok($JSON);
    $test->status_is($HTTP_UNAVAILABLE);
    $test->json_is( '/status' => 'unavailable' );
    $test->app->helper( gp_identity_workflow => $live );
};

subtest 'a bookmark write that conflicts answers 409' => sub {
    my $conflicted = GPForum::Test::ScriptedWorkflow->new(
        answer => { ok => 0, status => 'conflict', error => 'raced' } );
    $test->app->helper( gp_community_workflow => sub { return $conflicted; } );
    $test->get_ok('/__test/session/user-1')->status_is($HTTP_OK);
    $test->post_ok( '/t/thread-1/bookmark' => $JSON => form =>
          { command_id => $COMMAND_ID, csrf_token => _csrf_token() } );
    $test->status_is($HTTP_CONFLICT);
    $test->json_is( '/error' => 'raced' );
};

done_testing();

sub _login_ok ( $headers = {} ) {
    $test->reset_session;
    return $test->post_ok(
        '/login' => $headers => form => {
            command_id => $COMMAND_ID,
            csrf_token => _csrf_token(),
            identifier => 'giacomo_forum',
            password   => 'correct horse battery staple',
        }
    );
}

sub _csrf_token {
    $test->get_ok( '/__test/csrf' => $JSON )->status_is($HTTP_OK);
    my $response = $test->tx->res;

    return $response->json->{csrf_token};
}

sub _install_fakes ($application) {
    my $forum = GPForum::Test::ForumWebServices->new;
    my %fakes = (
        (
            map { $_ => $forum }
              qw(gp_category_reader gp_thread_reader gp_thread_detail_reader
              gp_post_reader gp_post_position gp_thread_read_state
              gp_attachment_store gp_suspension_store gp_home_page_reader)
        ),
        gp_command_idempotency     => GPForum::Test::CommandIdempotency->new,
        gp_identity_security_audit => GPForum::Test::IdentitySecurityAudit->new,
        gp_identity_store          => $identity,
        gp_permission_gate         => GPForum::Test::AllowPermissionGate->new,
        gp_rate_limiter            => GPForum::Test::AllowLimiter->new,
    );
    for my $helper ( sort keys %fakes ) {
        my $fake = $fakes{$helper};
        $application->helper( $helper => sub { return $fake; } );
    }

    my $routes = $application->routes;
    $routes->get('/__test/session/:user_id')->to(
        cb => sub ($controller) {
            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( json => { ok => 1 } );
        }
    );
    $routes->get('/__test/csrf')->to(
        cb => sub ($controller) {
            return $controller->render(
                json => { csrf_token => $controller->csrf_token } );
        }
    );

    return;
}

1;
