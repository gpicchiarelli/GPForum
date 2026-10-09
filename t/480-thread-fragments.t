# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::CommandIdempotency;
use GPForum::Test::ForumWebServices;

our $VERSION = '0.001';

const my $HTTP_OK        => 200;
const my $HTTP_FOUND     => 302;
const my $HTTP_FORBIDDEN => 403;
const my $FRAGMENT       => { 'HX-Request' => 'true' };

# The thread page's script (htmx) asks for the part of the page an action
# changed, with HX-Request: true, and swaps it in place; a browser without
# the script sends no header and gets the page, or the redirect, as before.
my $test = Test::Mojo->new('GPForum');
_install_forum_fakes($test);
_install_session_route($test);

# The page carries what the script needs: the list to append to, the bar to
# replace, the composer that posts in place, and a place for the message.
$test->get_ok('/t/thread-1')->status_is($HTTP_OK);
$test->element_exists('ol#posts');
$test->element_exists('#posts-pagination a[hx-get][hx-target="#posts"]');
$test->element_exists('#thread-toolbar[hx-target="#thread-toolbar"]');
$test->element_exists('#reply form[hx-post="/t/thread-1/replies"]');
$test->element_exists('#flash');
$test->element_exists('meta[name="htmx-config"]');

# The next posts, asked for by the script: the posts alone, and the way on
# sent to its own place. No layout, and never from the public cache.
$test->get_ok( '/t/thread-1' => $FRAGMENT )->status_is($HTTP_OK);
$test->content_unlike( qr/<html/msx, 'a fragment has no layout' );
$test->element_exists('li.ui-card-list__item article.post#post-post-1');
$test->element_exists('#posts-pagination[hx-swap-oob="true"]');
$test->element_exists_not('#thread-toolbar');
$test->header_isnt( 'X-GPForum-Cache' => 'hit' );

# Signed in: following the thread from the script gives back the bar, with
# the message the redirect would have flashed; without the script, the
# redirect.
$test->get_ok('/__test/session/user-1')->status_is($HTTP_OK);
$test->get_ok('/t/thread-1')->status_is($HTTP_OK);
my $csrf_token   = _csrf_token($test);
my $subscribe_id = _command_id( $test, '/t/thread-1/subscribe' );
my $reply_id     = _command_id( $test, '/t/thread-1/replies' );

$test->post_ok(
    '/t/thread-1/subscribe' => $FRAGMENT => form => {
        command_id => $subscribe_id,
        csrf_token => $csrf_token,
        preference => 'all',
    }
)->status_is($HTTP_OK);
$test->content_unlike( qr/<html/msx, 'the bar comes back without a layout' );
$test->element_exists('#thread-toolbar[hx-target="#thread-toolbar"]');
$test->element_exists_not('#thread-toolbar[hx-swap-oob]');
$test->element_exists('#flash[hx-swap-oob="true"] .flash--success');
$test->element_exists_not('article.post');

$test->get_ok('/t/thread-1')->status_is($HTTP_OK);
$subscribe_id = _command_id( $test, '/t/thread-1/subscribe' );
$test->post_ok(
    '/t/thread-1/subscribe' => form => {
        command_id => $subscribe_id,
        csrf_token => $csrf_token,
        preference => 'all',
    }
)->status_is($HTTP_FOUND);

# A post's own writes from the script -- an edit, a deletion -- come back as
# the post, for its place in the list, with the message; without the script,
# the redirect.
$test->get_ok('/t/thread-1')->status_is($HTTP_OK);
my $edit_id = _command_id( $test, '/p/post-1' );
$test->post_ok(
    '/p/post-1' => $FRAGMENT => form => {
        body_source => 'Edited',
        command_id  => $edit_id,
        csrf_token  => $csrf_token,
    }
)->status_is($HTTP_OK);
$test->content_unlike( qr/<html/msx, 'the post comes back without a layout' );
$test->element_exists('li[hx-target="this"] article.post#post-post-1');
$test->element_exists('#flash[hx-swap-oob="true"] .flash--success');
$test->element_exists_not('#thread-toolbar');
$test->element_exists_not('#reply');

$test->get_ok('/t/thread-1')->status_is($HTTP_OK);
my $delete_id = _command_id( $test, '/p/post-1/delete' );
$test->post_ok(
    '/p/post-1/delete' => form => {
        command_id => $delete_id,
        csrf_token => $csrf_token,
    }
)->status_is($HTTP_FOUND);
$test->get_ok('/t/thread-1')->status_is($HTTP_OK);
$test->element_exists(
    '#posts > li[hx-target="this"] form[hx-post="/p/post-1"]');

# A write that fails from the script -- here a form whose token has expired
# -- gets the message for its place and nothing for the target it asked for,
# so the page keeps what it had.
$test->post_ok(
    '/t/thread-1/replies' => $FRAGMENT => form => {
        body_source => 'A reply',
        command_id  => $reply_id,
        csrf_token  => 'expired',
    }
)->status_is($HTTP_FORBIDDEN);
$test->header_is( 'HX-Reswap' => 'none' );
$test->content_unlike( qr/<html/msx,
    'the failure comes back without a layout' );
$test->element_exists('#flash[hx-swap-oob="true"] .flash--error[role="alert"]');
$test->element_exists_not('article.post');

# The thread's own writes from the script -- a new title, another category,
# deletion, restoration -- come back as the page's head, with the breadcrumbs,
# the notices and the composer's place out of band, since each may have
# changed; without the script, the redirect.
$test->get_ok('/t/thread-1')->status_is($HTTP_OK);
my $title_id = _command_id( $test, '/t/thread-1/edit' );
$test->post_ok(
    '/t/thread-1/edit' => $FRAGMENT => form => {
        command_id => $title_id,
        csrf_token => $csrf_token,
        title      => 'Renamed',
    }
)->status_is($HTTP_OK);
$test->content_unlike( qr/<html/msx, 'the head comes back without a layout' );
$test->text_like( 'title' => qr/GPForum/msx, 'with the document title' );
$test->element_exists('#thread-header h1#thread-heading');
$test->element_exists('#thread-header #thread-toolbar');
$test->element_exists('#breadcrumbs[hx-swap-oob="true"] [aria-current="page"]');
$test->element_exists('#thread-notices[hx-swap-oob="true"]');
$test->element_exists('#reply[hx-swap-oob="true"] form[hx-post]');
$test->element_exists('#flash[hx-swap-oob="true"] .flash--success');
$test->element_exists_not('article.post');

$test->get_ok('/t/thread-1')->status_is($HTTP_OK);
my $thread_delete_id = _command_id( $test, '/t/thread-1/delete' );
$test->post_ok(
    '/t/thread-1/delete' => $FRAGMENT => form => {
        command_id => $thread_delete_id,
        csrf_token => $csrf_token,
    }
)->status_is($HTTP_OK);
$test->element_exists('#thread-header');
$test->element_exists('#thread-notices[hx-swap-oob="true"]');
$test->element_exists('#reply[hx-swap-oob="true"]');

# A hidden thread takes no replies: the page keeps the composer's place
# empty, and the way to restore it posts to the page's head.
$test->get_ok('/t/thread-deleted-1')->status_is($HTTP_OK);
$test->element_exists('div#reply[hidden]');
$test->element_exists_not('#reply form');
$test->element_exists(
'#thread-notices form[hx-post="/t/thread-deleted-1/restore"][hx-target="#thread-header"]'
);
my $thread_restore_id = _command_id( $test, '/t/thread-deleted-1/restore' );
$test->post_ok(
    '/t/thread-deleted-1/restore' => $FRAGMENT => form => {
        command_id => $thread_restore_id,
        csrf_token => $csrf_token,
    }
)->status_is($HTTP_OK);
$test->element_exists('#thread-header');
$test->element_exists('#thread-notices[hx-swap-oob="true"]');

# A reply from the script: the new post, for the list, and a composer with a
# fresh command id in place of the one that was spent.
$test->post_ok(
    '/t/thread-1/replies' => $FRAGMENT => form => {
        body_source => 'A reply',
        command_id  => $reply_id,
        csrf_token  => $csrf_token,
    }
)->status_is($HTTP_OK);
$test->content_unlike( qr/<html/msx, 'the reply comes back without a layout' );
$test->element_exists('li.ui-card-list__item article.post#post-post-created');
$test->element_exists('#reply[hx-swap-oob="true"] form[hx-post]');
my $fresh_id = _command_id( $test, '/t/thread-1/replies' );
ok(
    length $fresh_id && $fresh_id ne $reply_id,
    'the composer comes back with a new command id'
);
$test->element_exists('#flash[hx-swap-oob="true"] .flash--success');

done_testing();

sub _csrf_token {
    my ($test_object) = @_;

    my ($token) = $test_object->tx->res->body =~
      /name="csrf_token" [^>]+ value="([^"]+)"/msx;

    return $token;
}

sub _command_id {
    my ( $test_object, $form_action ) = @_;

    my $page  = $test_object->tx->res->dom;
    my $form  = $page->at(qq{form[action="$form_action"]});
    my $field = $form ? $form->at('input[name="command_id"]') : undef;

    return $field ? $field->attr('value') : undef;
}

sub _install_forum_fakes {
    my ($test_object) = @_;

    my $services = GPForum::Test::ForumWebServices->new;
    for my $helper (
        qw(
        gp_category_reader gp_thread_reader gp_thread_detail_reader
        gp_thread_composer gp_thread_store gp_post_reader gp_post_composer
        gp_post_store gp_post_position gp_thread_read_state gp_mention_store
        gp_mention_reader gp_bookmark_store gp_subscription_store
        gp_notification_dispatcher gp_search_service gp_rate_limiter
        gp_suspension_store gp_attachment_store
        )
      )
    {
        $test_object->app->helper( $helper => sub { return $services; } );
    }
    $test_object->app->helper(
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
        }
    );

    return;
}

sub _install_session_route {
    my ($test_object) = @_;

    my $routes = $test_object->app->routes;
    $routes->get('/__test/session/:user_id')->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( json => { ok => 1 } );
        }
    );

    return;
}

1;
