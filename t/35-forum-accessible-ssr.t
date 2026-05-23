package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::ForumWebServices;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 53;
const my $HTTP_FOUND     => 302;
const my $HTTP_OK        => 200;

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

$test->get_ok('/c/category-1');
$test->status_is($HTTP_OK);
$test->element_exists('section[aria-labelledby="category-heading"]');
$test->text_is( 'h1' => 'General' );
$test->element_exists('ol');
$test->element_exists('a[href="/t/thread-1"]');
$test->element_exists('nav[aria-label="Thread pagination"]');

$test->get_ok('/t/thread-1');
$test->status_is($HTTP_OK);
$test->element_exists('article[aria-labelledby="thread-heading"]');
$test->text_is( 'h1' => 'Welcome' );
$test->element_exists('section[aria-labelledby="posts-heading"]');
$test->element_exists('article[id="post-post-1"]');
$test->element_exists('a[href="#post-post-1"]');
$test->element_exists('form[action="/t/thread-1/replies"]');
$test->element_exists('label[for="reply-body"]');
$test->element_exists('textarea[id="reply-body"][name="body_source"]');
$test->element_exists('input[name="csrf_token"]');

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
$test->element_exists('label[for="search-query"]');
$test->element_exists('input[id="search-query"][name="q"]');
$test->element_exists('ol[aria-label="Search results"]');

$test->get_ok('/__test/session/user-1');
$test->status_is($HTTP_OK);
$test->get_ok('/t/thread-1');
$test->status_is($HTTP_OK);
$test->element_exists('section[aria-labelledby="reading-heading"]');
$test->get_ok('/new-thread');
my $csrf_token = _csrf_token($test);
$test->post_ok(
    '/threads' => form => {
        csrf_token  => $csrf_token,
        category_id => 'category-1',
        title       => 'A real thread',
        body_source => 'Opening post',
        visibility  => 'public',
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-created\z}msx );

$test->post_ok(
    '/t/thread-1/replies' => form => {
        csrf_token  => $csrf_token,
        body_source => 'A reply',
        visibility  => 'public',
    }
);
$test->status_is($HTTP_FOUND);
$test->header_like( Location => qr{/t/thread-1\#post-post-created\z}msx );

sub _install_forum_fakes {
    my ($test_object) = @_;

    my $services = GPForum::Test::ForumWebServices->new;
    for my $helper (
        qw(
        gp_category_reader gp_thread_reader gp_thread_detail_reader
        gp_thread_composer gp_thread_store gp_post_composer gp_post_store
        gp_post_position gp_thread_read_state gp_search_service gp_rate_limiter
        )
      )
    {
        $test_object->app->helper( $helper => sub { return $services; } );
    }

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

1;
