package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;
use Test::Mojo;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::ForumWebServices;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 14;
const my $HTTP_OK        => 200;
const my $ROOT_PATH      => q{/};

plan tests => $EXPECTED_TESTS;

my $test = Test::Mojo->new('GPForum');
$test->app->helper(
    gp_home_page_reader => sub {
        return GPForum::Test::ForumWebServices->new;
    }
);

$test->get_ok($ROOT_PATH);
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'GPForum' );
$test->element_exists(q{nav[aria-label="Forum actions"] a[href="/categories"]});
$test->element_exists(q{section[aria-labelledby="home-categories-heading"]});
$test->element_exists(q{a[href="/c/category-1"]});
$test->element_exists(q{a[href="/t/thread-1"]});
$test->element_exists(q{nav[aria-label="Latest discussion pagination"]});
$test->content_like(qr/Web [ ] processes/msx);

$test->get_ok('/?format=json');
$test->status_is($HTTP_OK);
$test->json_is( '/home/categories/0/category_id'         => 'category-1' );
$test->json_is( '/home/latest_threads/items/0/thread_id' => 'thread-1' );
$test->json_is( '/home/latest_threads/next_cursor' => 'home-thread-cursor' );

1;
