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

use GPForum::Test::CommandIdempotency;
use GPForum::Test::ForumWebServices;

our $VERSION = '0.001';

const my $EXPECTED_TESTS   => 246;
const my $FORM_SNIPPET     => 800;
const my $HTTP_BAD_REQUEST => 400;
const my $HTTP_FOUND       => 302;
const my $HTTP_OK          => 200;

plan tests => $EXPECTED_TESTS;

my $test = Test::Mojo->new('GPForum');
_install_forum_fakes($test);
_install_test_session_route($test);

$test->get_ok('/categories');
$test->status_is($HTTP_OK);
$test->element_exists('main');
$test->element_exists('section[aria-labelledby="categories-heading"]');
$test->text_is( 'h1' => 'Categories' );
$test->element_exists('nav[aria-label="Forum actions"]');
$test->element_exists('a[href="/c/category-1"]');

$test->get_ok('/login');
$test->status_is($HTTP_OK);
my $invalid_login_token      = _csrf_token($test);
my $invalid_login_command_id = _command_id($test);
$test->post_ok(
    '/login' => form => {
        command_id => $invalid_login_command_id,
        csrf_token => $invalid_login_token,
        identifier => q{},
        password   => q{},
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->element_exists('#login-error-summary[role="alert"][tabindex="-1"]');
$test->element_exists('form[aria-describedby="login-error-summary"]');
$test->element_exists(
'input#login-identifier[aria-invalid="true"][aria-describedby="login-identifier-error"]'
);
$test->element_exists(
'input#login-password[aria-invalid="true"][aria-describedby="login-password-error"]'
);
$test->element_exists('#login-error-summary a[href="#login-identifier"]');

$test->get_ok('/register');
$test->status_is($HTTP_OK);
my $invalid_register_token      = _csrf_token($test);
my $invalid_register_command_id = _command_id($test);
$test->post_ok(
    '/register' => form => {
        command_id   => $invalid_register_command_id,
        csrf_token   => $invalid_register_token,
        username     => 'gp',
        display_name => q{},
        email        => 'bad-email',
        password     => 'short',
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->element_exists('#register-error-summary[role="alert"][tabindex="-1"]');
$test->element_exists('form[aria-describedby="register-error-summary"]');
$test->element_exists(
'input#register-display-name[aria-invalid="true"][aria-describedby="register-display-name-error"]'
);
$test->element_exists(
'input#register-email[aria-invalid="true"][aria-describedby="register-email-error"]'
);
$test->element_exists('#register-error-summary a[href="#register-password"]');

$test->get_ok('/c/category-1');
$test->status_is($HTTP_OK);
$test->element_exists('section[aria-labelledby="category-heading"]');
$test->text_is( 'h1' => 'General' );

# 7.6: the breadcrumb ends at the page itself, not at "Categories".
$test->element_exists('nav.breadcrumbs a[href="/categories"]');
$test->text_is( 'nav.breadcrumbs [aria-current="page"]' => 'General' );
$test->element_exists('ol');
$test->element_exists('a[href="/t/thread-1"]');
$test->element_exists('a[href="/u/giacomo_forum"]');
$test->element_exists('nav[aria-label="Thread pagination"]');

$test->get_ok('/t/thread-1');
$test->status_is($HTTP_OK);
$test->element_exists('article[aria-labelledby="thread-heading"]');
$test->content_like(
    qr{<link [^>]* rel="canonical" [^>]* /t/thread-1/welcome}msx);
$test->element_exists('meta[name="robots"][content="index,follow"]');
$test->element_exists('meta[name="description"][content="First post"]');
$test->element_exists('meta[property="og:title"][content="Welcome"]');
$test->content_like(
    qr{<meta [^>]* property="og:url" [^>]* /t/thread-1/welcome}msx);
$test->text_is( 'h1' => 'Welcome' );
$test->element_exists('nav.breadcrumbs a[href="/categories"]');
$test->element_exists('nav.breadcrumbs a[href="/c/category-1"]');
$test->text_is( 'nav.breadcrumbs [aria-current="page"]' => 'Welcome' );
$test->element_exists('a[href="/u/giacomo_forum"]');
$test->element_exists('section[aria-labelledby="posts-heading"]');
$test->element_exists('article[id="post-post-1"]');
$test->element_exists('article[id="post-post-1"] a[href="/u/giacomo_forum"]');
$test->element_exists('a[href="#post-post-1"]');
$test->element_exists('form[action="/t/thread-1/replies"]');
$test->element_exists('label[for="reply-body"]');
$test->element_exists('textarea[id="reply-body"][name="body_source"]');
$test->element_exists('input[name="csrf_token"]');

$test->get_ok('/t/thread-1/welcome');
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Welcome' );

$test->get_ok('/new-thread');
$test->status_is($HTTP_OK);
$test->element_exists('section[aria-labelledby="new-thread-heading"]');
$test->text_is( 'h1' => 'Start a thread' );
$test->element_exists('label[for="thread-category"]');
$test->element_exists('select[id="thread-category"][name="category_id"]');
$test->element_exists('label[for="thread-title"]');
$test->element_exists('input[id="thread-title"][name="title"]');
$test->element_exists('label[for="thread-body"]');
$test->element_exists('textarea[id="thread-body"][name="body_source"]');

$test->get_ok('/search?q=welcome');
$test->status_is($HTTP_OK);
$test->element_exists('form[role="search"]');
$test->element_exists('form[role="search"][aria-describedby="search-help"]');
$test->element_exists('#search-help');
my @search_help =
  $test->tx->res->text =~ /Results [ ] respect [ ] visibility/gmsx;
is( scalar @search_help, 1, 'the search page states its help once' );
$test->element_exists('label[for="search-query"]');
$test->element_exists('input[id="search-query"][name="q"]');
$test->element_exists('fieldset legend');
$test->element_exists('p[role="status"]');
$test->element_exists('ol[aria-label="Search results"]');
$test->element_exists('mark');
$test->element_exists('a[href="/u/giacomo_forum"]');
$test->content_like(qr/Snippets [ ] only [ ] include [ ] content/msx);

$test->get_ok('/search?q=missing');
$test->status_is($HTTP_OK);
$test->element_exists('section[aria-labelledby="search-no-results-heading"]');
$test->content_like(qr/Try [ ] a [ ] broader [ ] query/msx);

$test->get_ok('/search?q=many&limit=2');
$test->status_is($HTTP_OK);
$test->element_exists('nav[aria-label="Search pagination"]');
$test->element_exists('nav[aria-label="Search pagination"] a[href*="limit=4"]');
$test->content_like(qr/2 [ ] results/msx);

# A word that filled every candidate slot was ranked over the newest matches
# only, and the page says so (8.10). A search the database cancelled at its
# statement timeout is a degraded page, not an error -- and the banner used to
# be missing from it: rendering sets the stash's status to the HTTP code, so
# the template never saw 'degraded' and the page said nothing had matched.
$test->get_ok('/search?q=capped');
$test->status_is($HTTP_OK);
$test->text_like(
    '#search-ranking-capped' => qr/1000 [ ] most [ ] recent [ ] matches/msx );
$test->get_ok('/search?q=welcome');
$test->element_exists_not('#search-ranking-capped');
$test->get_ok('/search?q=timeout');
$test->status_is($HTTP_OK);
$test->element_exists('section[aria-labelledby="search-status-heading"]');
$test->content_like(qr/Search [ ] is [ ] temporarily [ ] degraded/msx);
$test->element_exists_not(
    'section[aria-labelledby="search-no-results-heading"]');

$test->get_ok('/__test/session/user-1');
$test->status_is($HTTP_OK);
$test->get_ok('/t/thread-1');
$test->status_is($HTTP_OK);
$test->element_exists('section[aria-labelledby="reading-heading"]');
$test->element_exists('section[aria-labelledby="engagement-heading"]');
$test->element_exists('form[action="/t/thread-1/bookmark"]');
$test->element_exists(
    'form[action="/t/thread-1/bookmark"] input[name="command_id"]');
$test->element_exists('label[for="bookmark-note"]');
$test->element_exists('form[action="/t/thread-1/subscribe"]');
$test->element_exists(
    'form[action="/t/thread-1/subscribe"] input[name="command_id"]');
$test->element_exists('form[action="/t/thread-1/report"]');
$test->element_exists(
    'form[action="/t/thread-1/report"] input[name="command_id"]');
$test->element_exists(
    'form[action="/p/post-1/report"] input[name="command_id"]');
$test->element_exists('form[action="/p/post-1"]');
$test->element_exists('textarea[id="post-post-1-edit-body"]');
$test->element_exists('form[action="/p/post-1/delete"]');
$test->element_exists('form[action="/p/post-deleted-1/restore"]');
$test->element_exists(
    'form[action="/p/post-1/attachments/attachment-1/delete"]');
$test->element_exists(
'form[action="/p/post-1/attachments/attachment-1/delete"] input[name="command_id"]'
);
$test->element_exists(
    'form[action="/p/post-1/attachments"] input[name="command_id"]');
$test->element_exists('form[action="/t/thread-1/edit"]');
$test->element_exists('input[id="thread-edit-title"]');
$test->element_exists('form[action="/t/thread-1/delete"]');
$test->element_exists('form[action="/t/thread-1/move"]');
$test->element_exists('select[id="thread-move-category"]');
$test->element_exists_not('form[action="/t/thread-1/restore"]');
$test->get_ok('/t/thread-deleted-1');
$test->status_is($HTTP_OK);
$test->element_exists('form[action="/t/thread-deleted-1/restore"]');
$test->content_like(qr/This thread is hidden/ms);
my $thread_restore_id = _command_id( $test, '/t/thread-deleted-1/restore' );
$test->get_ok('/c/category-1');
$test->status_is($HTTP_OK);
$test->element_exists('form[action="/t/thread-deleted-1/restore"]');
$test->get_ok('/t/thread-1');
$test->status_is($HTTP_OK);
my $edit_command_id    = _command_id( $test, '/p/post-1' );
my $delete_command_id  = _command_id( $test, '/p/post-1/delete' );
my $restore_command_id = _command_id( $test, '/p/post-deleted-1/restore' );
my $title_command_id   = _command_id( $test, '/t/thread-1/edit' );
my $thread_delete_id   = _command_id( $test, '/t/thread-1/delete' );
my $thread_move_id     = _command_id( $test, '/t/thread-1/move' );
my $reply_command_id   = _command_id( $test, '/t/thread-1/replies' );
my $attachment_csrf    = _csrf_token($test);
my $attachment_command_id =
  _command_id( $test, '/p/post-1/attachments/attachment-1/delete' );
$test->post_ok(
    '/p/post-1/attachments/attachment-1/delete' => form => {
        command_id => $attachment_command_id,
        csrf_token => $attachment_csrf,
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-1\#post-post-1\z}msx );
$test->get_ok('/t/thread-1');
$test->status_is($HTTP_OK);
$test->content_like(qr/Attachment deleted/ms);
$test->get_ok('/bookmarks');
$test->status_is($HTTP_OK);
$test->element_exists('section[aria-labelledby="bookmarks-heading"]');
$test->element_exists('a[href="/t/thread-1"]');
$test->element_exists('nav[aria-label="Bookmark pagination"]');
$test->get_ok('/feed');
$test->status_is($HTTP_OK);
$test->element_exists('section[aria-labelledby="feed-heading"]');
$test->element_exists('ol[aria-label="Personal feed"]');
$test->element_exists('nav[aria-label="Feed pagination"]');
$test->get_ok('/notifications');
$test->status_is($HTTP_OK);
$test->element_exists('section[aria-labelledby="notifications-heading"]');
$test->element_exists('ol[aria-label="Notification inbox"]');
$test->element_exists('a[href="/t/thread-1#post-post-1"]');
$test->element_exists('form[action="/notifications/notification-1/read"]');
$test->element_exists('form[action="/notifications/read-all"]');
$test->element_exists('nav[aria-label="Notification pagination"]');
my $notice_csrf = _csrf_token($test);
$test->post_ok(
    '/notifications/notification-1/read' => form => {
        csrf_token => $notice_csrf,
    }
);
$test->status_is($HTTP_FOUND);
$test->header_is( Location => '/notifications' );
$test->get_ok('/notifications');
$test->status_is($HTTP_OK);
$test->content_like(qr/Notification marked as read/ms);
my $notice_all_csrf = _csrf_token($test);
$test->post_ok(
    '/notifications/read-all' => form => {
        csrf_token => $notice_all_csrf,
    }
);
$test->status_is($HTTP_FOUND);
$test->header_is( Location => '/notifications' );
$test->get_ok('/notifications');
$test->status_is($HTTP_OK);
$test->content_like(qr/Notifications marked as read/ms);
$test->get_ok('/mentions');
$test->status_is($HTTP_OK);
$test->element_exists('section[aria-labelledby="mentions-heading"]');
$test->element_exists('ol[aria-label="Mention list"]');
$test->element_exists('a[href="/u/reply_author"]');
$test->element_exists('nav[aria-label="Mention pagination"]');

$test->get_ok( '/notifications' => { 'Accept-Language' => 'it' } );
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Notifiche' );
$test->content_like(qr/Sei [ ] stato [ ] menzionato/msx);
$test->element_exists('ol[aria-label="Inbox notifiche"]');
$test->element_exists('nav[aria-label="Paginazione notifiche"]');
$test->get_ok( '/mentions' => { 'Accept-Language' => 'it' } );
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Menzioni' );
$test->content_like(qr/Menzione [ ] da/msx);
$test->element_exists('ol[aria-label="Elenco menzioni"]');
$test->get_ok('/new-thread');
my $invalid_thread_token      = _csrf_token($test);
my $invalid_thread_command_id = _command_id( $test, '/threads' );
$test->post_ok(
    '/threads' => form => {
        csrf_token  => $invalid_thread_token,
        category_id => 'category-1',
        command_id  => $invalid_thread_command_id,
        title       => q{},
        body_source => q{},
        visibility  => 'public',
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->element_exists('#thread-error-summary[role="alert"][tabindex="-1"]');
$test->element_exists('form[aria-describedby="thread-error-summary"]');
$test->element_exists(
'input#thread-title[aria-invalid="true"][aria-describedby="thread-title-error"]'
);
$test->element_exists(
'textarea#thread-body[aria-invalid="true"][aria-describedby="thread-body-error"]'
);
$test->element_exists('#thread-error-summary a[href="#thread-body"]');

$test->get_ok('/new-thread');
my $csrf_token        = _csrf_token($test);
my $thread_command_id = _command_id( $test, '/threads' );
$test->post_ok(
    '/threads' => form => {
        csrf_token  => $csrf_token,
        category_id => 'category-1',
        command_id  => $thread_command_id,
        title       => 'A real thread',
        body_source => 'Opening post',
        visibility  => 'public',
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-created\z}msx );
$test->get_ok('/t/thread-1');
$test->status_is($HTTP_OK);
$test->content_like(qr/Thread created/ms);
$test->element_exists(
    q{form[action="/t/thread-1/read"] input[name="command_id"]});
my $read_command_id = _command_id( $test, '/t/thread-1/read' );

$test->post_ok(
    '/t/thread-1/read' => form => {
        command_id         => $read_command_id,
        csrf_token         => $csrf_token,
        last_read_position => 1,
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-1\z}msx );
$test->get_ok('/t/thread-1');
$test->status_is($HTTP_OK);
$test->content_like(qr/Visible posts marked as read/ms);

$test->post_ok(
    '/t/thread-1/replies' => form => {
        csrf_token  => $csrf_token,
        body_source => 'A reply',
        command_id  => $reply_command_id,
        visibility  => 'public',
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-1\#post-post-created\z}msx );
$test->get_ok('/t/thread-1');
$test->status_is($HTTP_OK);
$test->content_like(qr/Reply posted/ms);

$test->post_ok(
    '/p/post-1' => form => {
        csrf_token  => $csrf_token,
        body_source => 'Edited post',
        command_id  => $edit_command_id,
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-1\#post-post-1\z}msx );

$test->post_ok(
    '/p/post-1/delete' => form => {
        csrf_token => $csrf_token,
        command_id => $delete_command_id,
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-1\z}msx );

$test->post_ok(
    '/p/post-deleted-1/restore' => form => {
        csrf_token => $csrf_token,
        command_id => $restore_command_id,
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-1\#post-post-deleted-1\z}msx );
$test->get_ok('/t/thread-1');
$test->status_is($HTTP_OK);
$test->content_like(qr/Post restored/ms);

$test->post_ok(
    '/t/thread-deleted-1/restore' => form => {
        csrf_token => $csrf_token,
        command_id => $thread_restore_id,
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-deleted-1\z}msx );
$test->get_ok('/t/thread-deleted-1');
$test->status_is($HTTP_OK);
$test->content_like(qr/Thread restored/ms);

$test->post_ok(
    '/t/thread-1/edit' => form => {
        csrf_token => $csrf_token,
        command_id => $title_command_id,
        title      => 'Edited Welcome',
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-1\z}msx );

$test->post_ok(
    '/t/thread-1/move' => form => {
        csrf_token  => $csrf_token,
        category_id => 'category-2',
        command_id  => $thread_move_id,
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-1\z}msx );

$test->post_ok(
    '/t/thread-1/delete' => form => {
        csrf_token => $csrf_token,
        command_id => $thread_delete_id,
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/c/category-1\z}msx );

sub _install_forum_fakes {
    my ($test_object) = @_;

    my $services = GPForum::Test::ForumWebServices->new;
    for my $helper (
        qw(
        gp_category_reader gp_thread_reader gp_thread_detail_reader
        gp_thread_composer gp_thread_store gp_post_reader gp_post_composer
        gp_post_store
        gp_post_position gp_thread_read_state gp_mention_store
        gp_mention_reader gp_bookmark_store gp_subscription_store
        gp_notification_dispatcher gp_search_service gp_rate_limiter
        gp_suspension_store gp_attachment_store
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
    $test_object->app->helper(
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
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

sub _csrf_token {
    my ($test_object) = @_;

    my $body = $test_object->tx->res->body;
    my ($token) = $body =~ /name="csrf_token" [^>]+ value="([^"]+)"/msx;

    return $token;
}

sub _command_id {
    my ( $test_object, $form_action ) = @_;

    my $body = $test_object->tx->res->body;
    if ($form_action) {
        return _command_id_in_form( $body, $form_action );
    }

    my ($command_id) = $body =~ /name="command_id" [^>]+ value="([^"]+)"/msx;

    return $command_id;
}

sub _command_id_in_form {
    my ( $body, $form_action ) = @_;

    my $quote  = q{"};
    my $marker = 'action=' . $quote . $form_action . $quote;
    my $start  = index $body, $marker;
    if ( $start < 0 ) {
        return;
    }

    my $chunk        = substr $body, $start, $FORM_SNIPPET;
    my ($command_id) = $chunk =~ /name="command_id" [^>]+ value="([^"]+)"/msx;

    return $command_id;
}

1;
