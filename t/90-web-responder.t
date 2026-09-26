# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::I18N;
use GPForum::Test::ResponderController;
use GPForum::Web::ErrorPayload;
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

# An HTML error page names catalog texts by the kind of failure, never the
# payload's English strings; a request-specific error is kept as detail.
my $payload = 'GPForum::Web::ErrorPayload';
is_deeply(
    $payload->page( $payload->unauthorized ),
    {
        detail      => undef,
        kind        => 'unauthorized',
        message_key => 'forum.error_unauthorized_message',
        title_key   => 'forum.error_unauthorized_title',
    },
    'sign-in required: its own texts, no internal code as detail'
);
is( $payload->page( $payload->csrf_failure )->{kind},
    'csrf', 'a stale form is told apart from a permission failure' );
is( $payload->page( $payload->csrf_failure )->{detail},
    undef, 'without naming the CSRF token' );
is(
    $payload->page( $payload->conflict( error => 'already replayed' ) )
      ->{detail},
    'already replayed',
    'a specific reason is kept as detail'
);
is_deeply(
    [
        @{ $payload->page( { status => 'teapot' } ) }{qw(title_key message_key)}
    ],
    [ 'forum.error_title', 'forum.error_default' ],
    'an unknown kind falls back to the generic texts'
);
my $i18n = GPForum::Service::I18N->new;

for my $locale ( @{ $i18n->supported_locales } ) {
    is_deeply(
        [
            grep { !$i18n->has_key( $locale, $_ ) }
              @{ $payload->page_text_keys }
        ],
        [],
        "every error page text exists in $locale"
    );
}

done_testing();

1;
