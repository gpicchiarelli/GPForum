package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::AdminWebServices;
use GPForum::Test::AllowPermissionGate;
use GPForum::Test::ForumWebServices;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

my @component_names = qw(
  alert badge dialog empty_state loading page_header pagination section_header
  status_badge
);
for my $component_name (@component_names) {
    ok( -e path( 'templates/components', "$component_name.html.ep" ),
        "$component_name component partial exists" );
}

for my $template (
    qw(
    templates/admin/audit.html.ep
    templates/admin/dashboard.html.ep
    templates/admin/roles.html.ep
    templates/admin/users.html.ep
    templates/forum/categories.html.ep
    templates/forum/category.html.ep
    templates/forum/search.html.ep
    templates/forum/thread.html.ep
    templates/identity/profile.html.ep
    templates/moderation/actions.html.ep
    templates/moderation/reports.html.ep
    templates/moderation/suspensions.html.ep
    templates/privacy/dashboard.html.ep
    templates/privacy/review.html.ep
    )
  )
{
    like(
        path($template)->slurp,
        qr/include [ ] 'components\/page_header'/msx,
        "$template uses shared page header"
    );
}

my $css = path('assets/css/gpforum-ssr.css')->slurp;
for my $selector (
    qw(
    ui-page-header ui-section-header ui-card-list ui-empty-state ui-badge
    ui-alert ui-dialog ui-pagination
    )
  )
{
    like( $css, qr/[.]$selector\b/msx, "$selector CSS primitive exists" );
}

like( $css, qr/--font-size-sm/msx, 'typography scale is tokenized' );
like( $css, qr/--space-7/msx,      'spacing scale is tokenized' );
like(
    $css,
    qr/--color-surface-warning/msx,
    'semantic warning color is tokenized'
);
unlike( _all_template_source(), qr/\sstyle=/msx,
    'SSR templates do not introduce inline CSS' );

my $forum = Test::Mojo->new('GPForum');
_install_forum_fakes($forum);
_install_test_session_route($forum);
$forum->get_ok('/__test/session/user-1')->status_is($HTTP_OK);

for my $route (
    qw(
    /
    /categories
    /search?q=missing
    /bookmarks
    /feed
    /notifications
    /mentions
    )
  )
{
    $forum->get_ok($route)->status_is($HTTP_OK);
    _single_main_ok( $forum, "$route has one document main landmark" );
}

$forum->get_ok('/notifications')->status_is($HTTP_OK);
$forum->element_exists('.ui-page-header');
$forum->element_exists('ol.ui-card-list[aria-label="Notification inbox"]');
$forum->element_exists('.ui-pagination[aria-label="Notification pagination"]');

$forum->get_ok('/search?q=missing')->status_is($HTTP_OK);
$forum->element_exists(
    '.ui-empty-state[aria-labelledby="search-no-results-heading"]');

$forum->get_ok('/categories')->status_is($HTTP_OK);
$forum->element_exists('ul.ui-card-list[aria-label="Forum categories"]');

my $admin = Test::Mojo->new('GPForum');
_install_admin_fakes($admin);
_install_test_session_route($admin);
$admin->get_ok('/__test/session/admin-1')->status_is($HTTP_OK);

for my $route (
    qw(/admin /admin/users /admin/roles /admin/audit /admin/jobs /admin/status))
{
    $admin->get_ok($route)->status_is($HTTP_OK);
    _single_main_ok( $admin, "$route has one document main landmark" );
}

$admin->get_ok( '/admin/jobs' => { 'Accept-Language' => 'it' } )
  ->status_is($HTTP_OK);
$admin->text_is( 'h1' => 'Job asincroni' );
$admin->content_like(qr/Stato [ ] outbox/msx);
$admin->element_exists('.ui-page-header .ui-action-list');
$admin->element_exists('ol.ui-card-list[aria-label="Elenco outbox admin"]');

$admin->get_ok('/admin/status')->status_is($HTTP_OK);
$admin->element_exists('.ui-badge.ui-badge--success');
$admin->element_exists('ol[aria-label="Admin readiness checks"]');

$admin->get_ok('/admin/roles')->status_is($HTTP_OK);
$admin->element_exists('ol.ui-card-list[aria-label="Admin role list"]');
$admin->element_exists('ol.ui-card-list[aria-label="Admin permission list"]');

done_testing();

sub _single_main_ok {
    my ( $test_object, $message ) = @_;

    my $main_count = $test_object->tx->res->dom->find('main')->size;
    is( $main_count, 1, $message );

    return;
}

sub _all_template_source {
    my $source = q{};

    for my $template (
        path('templates')->list_tree->grep(qr/[.]html[.]ep\z/msx)->each )
    {
        $source .= $template->slurp;
    }

    return $source;
}

sub _install_forum_fakes {
    my ($test_object) = @_;

    my $services = GPForum::Test::ForumWebServices->new;
    for my $helper (
        qw(
        gp_category_reader gp_thread_reader gp_thread_detail_reader
        gp_thread_composer gp_thread_store gp_post_composer gp_post_store
        gp_post_position gp_thread_read_state gp_mention_store
        gp_mention_reader gp_bookmark_store gp_subscription_store
        gp_notification_dispatcher gp_report_store gp_search_service
        gp_rate_limiter gp_suspension_store gp_attachment_store
        gp_home_page_reader
        )
      )
    {
        $test_object->app->helper( $helper => sub { return $services; } );
    }
    $test_object->app->helper(
        gp_feed_reader => sub {
            return GPForum::Test::ForumWebServices->new( mode => 'feed' );
        }
    );

    return;
}

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

1;
