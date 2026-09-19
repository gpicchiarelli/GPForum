package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::ResponderController;
use GPForum::Web::Responder;

our $VERSION = '0.001';

const my $HTTP_OK        => 200;
const my $HTTP_NOT_FOUND => 404;
const my $HTTP_FORBIDDEN => 403;

my $responder = GPForum::Web::Responder->new;

my $html = GPForum::Test::ResponderController->new(
    format        => 'html',
    accept_header => 'text/html',
);
$responder->payload(
    {
        controller => $html,
        payload    => { title => 'Categories' },
        status     => $HTTP_OK,
        template   => 'forum/categories',
    }
);
is( $html->last_render->{template},
    'forum/categories', 'HTML payload uses the page template' );
is( $html->last_render->{title},
    'Categories', 'HTML payload spreads view-model fields' );
is( $html->last_render->{status}, $HTTP_OK, 'HTML payload keeps HTTP status' );

my $json = GPForum::Test::ResponderController->new( format => 'json' );
$responder->payload(
    {
        controller => $json,
        payload    => { title => 'Categories' },
        status     => $HTTP_OK,
        template   => 'forum/categories',
    }
);
is_deeply(
    $json->last_render->{json},
    { title => 'Categories' },
    'JSON payload returns the view-model hash'
);
is( $json->last_render->{status}, $HTTP_OK, 'JSON payload keeps HTTP status' );

my $cached = GPForum::Test::ResponderController->new(
    format        => 'html',
    accept_header => 'text/html',
);
$responder->payload(
    {
        cache_options => {
            key  => 'forum-ssr:categories:/c',
            tags => ['forum:categories'],
        },
        controller => $cached,
        payload    => { title => 'Categories' },
        status     => $HTTP_OK,
        template   => 'forum/categories',
    }
);
is( $cached->last_render->{key},
    'forum-ssr:categories:/c',
    'anonymous HTML payload can go through public HTTP cache' );

my $error_html = GPForum::Test::ResponderController->new(
    format        => 'html',
    accept_header => 'text/html',
);
$responder->error(
    {
        controller => $error_html,
        payload    => { error => 'not found', title => 'Not found' },
        status     => $HTTP_NOT_FOUND,
    }
);
is( $error_html->last_render->{template},
    'forum/error', 'HTML errors use the shared error template' );
is( $error_html->last_render->{status},
    $HTTP_NOT_FOUND, 'HTML errors keep the HTTP status' );

my $error_json = GPForum::Test::ResponderController->new( format => 'json' );
$responder->error(
    {
        controller => $error_json,
        payload    => { error => 'Bad CSRF token', status => 'forbidden' },
        status     => $HTTP_FORBIDDEN,
    }
);
is(
    $error_json->last_render->{json}{error},
    'Bad CSRF token',
    'JSON errors return the error payload'
);

my $actor =
  GPForum::Test::ResponderController->new( session_user_id => 'user-1' );
is( $responder->user_id($actor),
    'user-1', 'responder reads the current session user' );

done_testing();

1;
