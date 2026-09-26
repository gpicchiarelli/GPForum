# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::AdminWebServices;
use GPForum::Test::AllowLimiter;
use GPForum::Test::AllowPermissionGate;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::DenyLimiter;
use GPForum::Test::DenyPermissionGate;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_FOUND        => 302;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_NOT_FOUND    => 404;
const my $HTTP_CONFLICT     => 409;
const my $HTTP_TOO_MANY     => 429;

my $test           = Test::Mojo->new('GPForum');
my $admin_services = _install_admin_fakes($test);
_install_test_session_route($test);

_get_json_ok( $test, '/admin' );
$test->status_is($HTTP_UNAUTHORIZED);
$test->json_is( '/status' => 'unauthorized' );
$test->json_is( '/error'  => 'authentication required' );

# 7.2 and 7.3: a protected page asks a visitor to sign in -- the HTTP 401 used
# to overwrite the payload's status, so the links never rendered -- and says
# so in the visitor's language instead of an internal error code.
my $error_section = 'section[aria-labelledby="forum-error-heading"]';
$test->get_ok('/admin');
$test->status_is($HTTP_UNAUTHORIZED);
$test->element_exists(qq{$error_section a[href="/login"]});
$test->element_exists(qq{$error_section a[href="/register"]});
$test->text_is( '#forum-error-heading' => 'Sign in required' );
$test->get_ok( '/admin' => { 'Accept-Language' => 'it' } );
$test->status_is($HTTP_UNAUTHORIZED);
$test->text_is( '#forum-error-heading' => 'Accesso richiesto' );
$test->text_is(
    qq{$error_section a[href="/login"]} => 'Accedi per continuare' );
$test->content_unlike(qr/authentication [ ] required/msxi);

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
$test->element_exists(q{nav[aria-label="Admin"] a[href="/admin/categories"]});
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
$test->element_exists('form[action="/admin/roles"] input[name="command_id"]');

$test->get_ok('/admin/categories');
$test->status_is($HTTP_OK);
$test->element_exists(q{ol[aria-label="Admin category list"]});
$test->element_exists(q{form[action="/admin/categories"]});
$test->element_exists(
    'form[action="/admin/categories"] input[name="command_id"]');
$test->element_exists(q{form[action="/admin/categories/category-1"]});
$test->element_exists(
    'form[action="/admin/categories/category-1"] input[name="command_id"]');

_get_json_ok( $test, '/admin/categories' );
$test->status_is($HTTP_OK);
$test->json_is( '/categories/0/title' => 'General' );
$test->json_is(
    '/categories/0/ui/heading_id' => 'category-category-1-heading' );

$test->post_ok('/admin/roles');
$test->status_is($HTTP_FORBIDDEN);

$test->post_ok(
    '/admin/roles' => { Accept => 'application/json' } => form => {
        command_id => 'role-invalid-1',
        csrf_token => $csrf_token,
        name       => q{},
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/name' => 'name is required' );

$test->post_ok(
    '/admin/roles' => { Accept => 'application/json' } => form => {
        command_id  => 'role-create-1',
        csrf_token  => $csrf_token,
        description => 'Scoped admin',
        name        => 'space_admin',
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'    => 'role_created' );
$test->json_is( '/role/name' => 'space_admin' );

$test->post_ok(
    '/admin/roles' => form => {
        command_id  => 'role-create-html',
        csrf_token  => $csrf_token,
        description => 'Scoped admin',
        name        => 'space_admin',
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/admin/roles\z}msx );
$test->get_ok('/admin/roles');
$test->status_is($HTTP_OK);
$test->text_is( 'p.flash--success[role="status"]' => 'Role created' );

$test->post_ok(
    '/admin/permissions' => { Accept => 'application/json' } => form => {
        action        => 'view',
        command_id    => 'permission-create-1',
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
        command_id    => 'attach-invalid-1',
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
        command_id    => 'attach-1',
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
$test->element_exists(
'form[action="/admin/role-bindings/binding-1/revoke"] input[name="command_id"]'
);

$test->post_ok(
    '/admin/users/user-2/roles' => { Accept => 'application/json' } => form => {
        command_id    => 'bind-invalid-1',
        csrf_token    => $csrf_token,
        resource_type => 'global',
        role_id       => q{},
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/role_id' => 'role_id is required' );

$test->post_ok(
    '/admin/users/user-2/roles' => { Accept => 'application/json' } => form => {
        command_id    => 'bind-1',
        csrf_token    => $csrf_token,
        resource_type => 'global',
        role_id       => 'role-1',
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'          => 'role_bound' );
$test->json_is( '/binding/role_id' => 'role-1' );

# ADR 0079: a destructive action states its consequence and requires the
# operator to confirm it; without the confirmation the server refuses.
$test->get_ok('/admin/users/user-1/roles');
$test->element_exists(
        'form[action="/admin/role-bindings/binding-1/revoke"] '
      . 'input[type="checkbox"][name="confirm"][required]' );
$test->element_exists(
    'form[action="/admin/role-bindings/binding-1/revoke"] button.button--danger'
);
$test->content_like( qr/loses [ ] this [ ] role/msx,
    'the consequence is stated beside the button' );
$test->post_ok(
    '/admin/role-bindings/binding-1/revoke' =>
      { Accept => 'application/json' } => form => {
        command_id => 'revoke-unconfirmed',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_like( '/errors/confirm' => qr/Confirm/msx );

$test->post_ok(
    '/admin/role-bindings/binding-1/revoke' =>
      { Accept => 'application/json' } => form => {
        confirm    => 1,
        command_id => 'revoke-1',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'             => 'role_binding_revoked' );
$test->json_is( '/binding/revoked_at' => '2026-05-23T12:00:00Z' );

# 6.5: the jobs page says whether search is behind and how its last rebuild
# went, and rebuilds it or purges the page cache under a command id.
$test->get_ok('/admin/jobs');
my $jobs_page = $test->tx->res->dom;
my $maintenance =
  $jobs_page->at('section[aria-labelledby="admin-maintenance-heading"]');
ok( $maintenance, 'the jobs page has a maintenance section' );
my $maintenance_text = $maintenance ? $maintenance->all_text : q{};
like(
    $maintenance_text,
    qr/Behind .* 2 [ ] events [ ] waiting/msx,
    'with the search lag'
);
like(
    $maintenance_text,
    qr/10 [ ] indexed, [ ] 5 [ ] unchanged, [ ] 1 [ ] removed/msx,
    'and the last rebuild'
);

for my $action (qw(/admin/search/rebuild /admin/cache/purge)) {
    my $input =
      $jobs_page->at(qq{form[action="$action"] input[name=command_id]});
    like( $input ? $input->attr('value') : q{},
        qr/\S/msx, "$action carries its own command id" );
}
$test->post_ok(
    '/admin/search/rebuild' => { Accept => 'application/json' } => form =>
      { csrf_token => $csrf_token } );
$test->status_is($HTTP_BAD_REQUEST);
$test->post_ok(
    '/admin/search/rebuild' => { Accept => 'application/json' } => form => {
        command_id => 'rebuild-1',
        csrf_token => $csrf_token,
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'        => 'search_rebuild_requested' );
$test->json_is( '/result/run_id' => 'run-1' );
$test->post_ok( '/admin/cache/purge' => form =>
      { command_id => 'purge-1', csrf_token => $csrf_token } );
$test->status_is($HTTP_FOUND);
$test->header_is( Location => '/admin/jobs' );
$test->get_ok('/admin/jobs');
$test->content_like(
    qr/Public [ ] page [ ] cache [ ] purged/msx,
    'the purge is confirmed on the jobs page'
);
is_deeply( [ map { $_->[0] } @{ $admin_services->maintenance_calls } ],
    [qw(rebuild purge)], 'each ran once, as the signed-in administrator' );

# ADR 0056: a dead letter is replayed from the jobs page, once.
$test->get_ok('/admin/jobs');
my $replay_form = 'form[action="/admin/dead-letters/dead-letter-1/replay"]';
$test->element_exists($replay_form);
my $jobs_dom = $test->tx->res->dom;
like( $jobs_dom->at("$replay_form input[name=command_id]")->attr('value'),
    qr/\S/msx, 'the replay form carries its own command id' );
$test->element_exists("$replay_form button[type=submit][aria-describedby]");
$test->element_exists_not(
    'form[action="/admin/dead-letters/dead-letter-replayed/replay"]');
like(
    $jobs_dom->at(
        q{ol[aria-label="Admin dead-letter list"] > li:nth-child(2) dl})
      ->all_text,
    qr/Replay/msx,
    q{a dead letter already replayed shows its replay instead of the button}
);

$test->post_ok('/admin/dead-letters/dead-letter-1/replay');
$test->status_is($HTTP_FORBIDDEN);
$test->text_is( '#forum-error-heading' => 'Form expired' );
$test->content_unlike( qr/Bad [ ] CSRF [ ] token/msx,
    'a stale form says so, not the internal token name' );

$test->post_ok( '/admin/dead-letters/dead-letter-1/replay' =>
      { Accept => 'application/json' } => form => { csrf_token => $csrf_token }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_has('/errors/command_id');

$test->post_ok(
    '/admin/dead-letters/dead-letter-1/replay' =>
      { Accept => 'application/json' } => form => {
        command_id => 'replay-1',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'             => 'dead_letter_replayed' );
$test->json_is( '/replayed/outbox_id' => 'outbox-replay-1' );
is_deeply( [ map { $_->{via} } @{ $admin_services->dead_letter_replays } ],
    ['web'], 'the replay is audited as made from the console' );
ok( $admin_services->dead_letter_replays->[0]{actor_user_id},
    'by the signed-in administrator' );

$test->post_ok(
    '/admin/dead-letters/dead-letter-replayed/replay' =>
      { Accept => 'application/json' } => form => {
        command_id => 'replay-2',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_CONFLICT);
$test->json_like( '/error' => qr/already [ ] replayed/msx );

# The HTML page states the conflict in the visitor's language and keeps the
# specific reason as detail, since it is not one of the generic messages.
$test->post_ok(
    '/admin/dead-letters/dead-letter-replayed/replay' =>
      { 'Accept-Language' => 'it' } => form => {
        command_id => 'replay-2b',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_CONFLICT);
$test->text_is( '#forum-error-heading' => 'Conflitto' );
$test->text_like(
    "$error_section .error-detail" => qr/already [ ] replayed/msx );

$test->post_ok(
    '/admin/dead-letters/nowhere/replay' => { Accept => 'application/json' } =>
      form => {
        command_id => 'replay-3',
        csrf_token => $csrf_token,
      }
);
$test->status_is($HTTP_NOT_FOUND);

$test->post_ok(
    '/admin/dead-letters/dead-letter-1/replay' => form => {
        command_id => 'replay-4',
        csrf_token => $csrf_token,
    }
);
$test->status_is($HTTP_FOUND);
$test->header_is( Location => '/admin/jobs' );

$test->post_ok('/admin/categories');
$test->status_is($HTTP_FORBIDDEN);

$test->post_ok(
    '/admin/categories' => { Accept => 'application/json' } => form => {
        command_id => 'category-invalid-1',
        csrf_token => $csrf_token,
        title      => q{},
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->json_is( '/errors/title' => 'title is required' );

$test->post_ok(
    '/admin/categories' => { Accept => 'application/json' } => form => {
        command_id => 'category-create-1',
        csrf_token => $csrf_token,
        title      => 'General',
    }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'         => 'category_created' );
$test->json_is( '/category/title' => 'General' );

$test->post_ok(
    '/admin/categories' => form => {
        command_id => 'category-create-html',
        csrf_token => $csrf_token,
        title      => 'General',
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/admin/categories\z}msx );
$test->get_ok('/admin/categories');
$test->status_is($HTTP_OK);
$test->text_is( 'p.flash--success[role="status"]' => 'Category created' );

$test->post_ok(
    '/admin/categories/category-1' => { Accept => 'application/json' } =>
      form => {
        command_id => 'category-update-1',
        csrf_token => $csrf_token,
        title      => 'Updated',
      }
);
$test->status_is($HTTP_OK);
$test->json_is( '/status'         => 'category_updated' );
$test->json_is( '/category/title' => 'Updated' );

$test->post_ok(
    '/admin/categories/missing' => { Accept => 'application/json' } => form => {
        command_id => 'category-update-missing',
        csrf_token => $csrf_token,
        title      => 'Missing',
    }
);
$test->status_is($HTTP_NOT_FOUND);

$test->app->helper(
    gp_rate_limiter => sub { return GPForum::Test::DenyLimiter->new; } );
$test->post_ok(
    '/admin/roles' => { Accept => 'application/json' } => form => {
        csrf_token => $csrf_token,
        name       => 'TooFast',
    }
);
$test->status_is($HTTP_TOO_MANY);
$test->app->helper(
    gp_rate_limiter => sub { return GPForum::Test::AllowLimiter->new; } );

_get_json_ok( $test, '/admin/audit' );
$test->status_is($HTTP_OK);
$test->json_is( '/audit_rows/0/audit_id' => 'audit-1' );
$test->json_is(
    '/audit_rows/0/metadata_items/0/value' => 'least privilege review' );

$test->get_ok('/admin/audit');
$test->status_is($HTTP_OK);
$test->element_exists(q{ol[aria-label="Admin audit log"]});
$test->content_like(qr/least [ ] privilege [ ] review/msx);

# ADR 0079's filters. A value that is not a uuid never reaches PostgreSQL,
# where a uuid column would reject the whole query: the form comes back with
# the error, the value kept for correcting, and nothing searched.
{
    my $services = $test->app->build_controller->gp_admin_audit_review;
    my $before   = $services->searched;
    $test->get_ok(
        '/admin/audit?actor_id=not-a-uuid&action=role_binding.created');
    $test->status_is($HTTP_BAD_REQUEST);
    $test->element_exists('#audit-filter-errors');
    $test->element_exists('#audit-actor[aria-invalid="true"]');
    $test->element_exists('#audit-actor[value="not-a-uuid"]');
    $test->element_exists('#audit-action[value="role_binding.created"]');
    is( $services->searched, $before, 'an invalid filter runs no query' );

    $test->get_ok( '/admin/audit?correlation_id='
          . '018f1000-0000-7000-8000-000000000001&from=2026-05-01' );
    $test->status_is($HTTP_OK);
    $test->element_exists(
        '#audit-correlation[value="018f1000-0000-7000-8000-000000000001"]');
    $test->element_exists('#audit-from[type="date"][value="2026-05-01"]');

    $test->get_ok('/admin/audit?action=paged');
    $test->element_exists(
        'a[rel="next"][href*="action=paged"][href*="after=CURSOR"]',
        'the next page keeps the filters' );
}

$test->app->helper(
    gp_permission_gate => sub {
        return GPForum::Test::DenyPermissionGate->new;
    }
);

# ADR 0110: a refusal names the permission that was checked, so an operator
# can tell from the log why a member got 403.
my @denials;
my $level = $test->app->log->level;
$test->app->log->level('info');
my $listener = $test->app->log->on(
    message => sub {
        my ( undef, undef, @lines ) = @_;
        push @denials, grep { /\A permission [ ] denied/msx } @lines;
    }
);
_get_json_ok( $test, '/admin' );
$test->status_is($HTTP_FORBIDDEN);
$test->app->log->unsubscribe( message => $listener );
$test->app->log->level($level);
is(
    $denials[0] // q{},
    'permission denied: user admin-1 lacks admin_console.view'
      . ' (needs a global binding) on /admin',
    'the refusal is logged with the permission checked and its scope'
);
_get_json_ok( $test, '/admin/jobs' );
$test->status_is($HTTP_FORBIDDEN);

done_testing();

sub _install_admin_fakes {
    my ($test_object) = @_;

    my $services = GPForum::Test::AdminWebServices->new;
    $test_object->app->helper( gp_role_catalog   => sub { return $services; } );
    $test_object->app->helper( gp_category_store => sub { return $services; } );
    $test_object->app->helper(
        gp_role_binding_store => sub { return $services; } );
    $test_object->app->helper(
        gp_permission_review => sub { return $services; } );
    $test_object->app->helper(
        gp_admin_audit_review => sub { return $services; } );
    $test_object->app->helper(
        gp_admin_console_reader => sub { return $services; } );
    $test_object->app->helper(
        gp_dead_letter_replay => sub { return $services; } );
    $test_object->app->helper(
        gp_admin_maintenance => sub { return $services; } );
    $test_object->app->helper(
        gp_permission_gate => sub {
            return GPForum::Test::AllowPermissionGate->new;
        }
    );
    $test_object->app->helper(
        gp_rate_limiter => sub { return GPForum::Test::AllowLimiter->new; } );
    $test_object->app->helper(
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
        }
    );

    return $services;
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
