# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

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
  admin_table alert badge breadcrumbs card confirmation dialog empty_state
  error_summary field_error flash_messages identity_nav loading locale_selector
  moderation_indicator notification_surface page_header pagination primary_nav
  section_header site_footer site_header status_badge status_banner
  theme_selector
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
    templates/legal/page.html.ep
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
    ui-alert ui-dialog ui-pagination ui-status-banner ui-confirmation
    ui-moderation-indicator ui-admin-table ui-notification-surface
    form-error-summary field-error visually-hidden
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
for my $component_name (qw(site_header breadcrumbs flash_messages site_footer))
{
    like(
        path('templates/layouts/default.html.ep')->slurp,
        qr/include [ ] 'components\/$component_name'/msx,
        "base layout uses shared $component_name shell partial"
    );
}
like(
    path('templates/identity/login.html.ep')->slurp,
    qr/components\/error_summary/msx,
    'login uses shared form error summary'
);
like(
    path('templates/forum/new_thread.html.ep')->slurp,
    qr/components\/field_error/msx,
    'thread creation uses shared field errors'
);
like(
    path('templates/notifications/inbox.html.ep')->slurp,
    qr/components\/notification_surface/msx,
    'notification inbox uses shared notification surface'
);
like( path('templates/notifications/inbox.html.ep')->slurp,
    qr/notifications_read_all/msx, 'notification inbox exposes mark-all-read' );
like(
    path('templates/moderation/actions.html.ep')->slurp,
    qr/components\/moderation_indicator/msx,
    'moderation action history uses shared moderation indicator'
);
like(
    path('templates/admin/status.html.ep')->slurp,
    qr/components\/admin_table/msx,
    'admin status uses shared table primitive'
);
like(
    path('templates/forum/search.html.ep')->slurp,
    qr/components\/status_banner/msx,
    'search degraded state uses shared status banner'
);
like(
    path('templates/forum/thread.html.ep')->slurp,
    qr/ui_trusted_html[(]\$post->\{body\}, [ ] 'forum[.]post[.]body'/msx,
    'thread raw post body rendering goes through render policy helper'
);
like(
    path('templates/forum/thread.html.ep')->slurp,
    qr/post_attachment_delete/msx,
    'thread exposes author attachment delete'
);
like(
    path('templates/forum/search.html.ep')->slurp,
    qr/ui_trusted_html[(]\$result->\{snippet_html\}, [ ] 'search[.]snippet'/msx,
    'search snippet highlighting goes through render policy helper'
);

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

# 7.5: the header holds the brand, the primary navigation and the identity
# links. The language and theme forms -- two POST forms with their own Apply
# buttons -- collided with them at 800px and made the header taller than a
# phone's screen; they live in the footer.
$forum->element_exists('header.site-header nav.site-nav');
$forum->element_exists_not('header.site-header form.locale-form');
$forum->element_exists_not('header.site-header form.theme-form');
$forum->element_exists('footer.site-footer form.locale-form');
$forum->element_exists('footer.site-footer form.theme-form');

my $anonymous = Test::Mojo->new('GPForum');
_install_forum_fakes($anonymous);
$anonymous->get_ok('/categories')->status_is($HTTP_OK);
$anonymous->element_exists('header.site-header a[href="/login"]');
$anonymous->element_exists_not('header.site-header a[href="/password/reset"]');

my ($narrow) =
  $css =~ /\@media [ ] [(]max-width: [ ] 1100px[)] [ ] [{] (.*?) ^[}]/msx;
like(
    $narrow // q{},
    qr/grid-template-areas: \s* "brand [ ] identity" \s* "nav [ ] nav"/msx,
    'below 1100px the header is two rows: brand and identity, then navigation'
);
like(
    $narrow // q{},
    qr/[.]site-header [ ] [.]site-nav [ ] [{] [^}]* overflow-x: \s* auto/msx,
    'and the navigation scrolls sideways instead of stacking'
);

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
$admin->element_exists(
    'table.ui-admin-table[aria-label="Admin query budget list"]');

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
