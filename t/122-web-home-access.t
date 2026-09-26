# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Test::ResponderController;
use GPForum::Web::HomeAccess;
use Test::More;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_SERVER_ERROR => 500;
const my $CATEGORY_LIMIT    => 12;
const my $THREAD_LIMIT      => 20;

my $access = GPForum::Web::HomeAccess->new;
is_deeply(
    $access->query('cursor-1'),
    {
        after          => 'cursor-1',
        category_limit => $CATEGORY_LIMIT,
        thread_limit   => $THREAD_LIMIT,
    },
    'query keeps the after cursor and home reader limits'
);
is_deeply(
    $access->page_payload( { categories => [] }, { workers => 1 } ),
    {
        home    => { categories => [] },
        runtime => { workers    => 1 },
    },
    'page_payload keeps home and runtime hashes'
);
is_deeply(
    $access->failure_payload,
    {
        error  => 'home_unavailable',
        status => 'fail',
    },
    'failure_payload keeps the home_unavailable contract'
);

my $html = GPForum::Test::ResponderController->new;
$access->render_page(
    $html,
    {
        home    => { categories => [] },
        runtime => { workers    => 1 },
    }
);
is( $html->last_render->{status}, $HTTP_OK, 'render_page uses HTTP 200' );
is( $html->last_render->{template},
    'home/index', 'render_page uses the home index template' );

$access->render_unavailable($html);
is( $html->last_render->{status},
    $HTTP_SERVER_ERROR, 'render_unavailable uses HTTP 500' );
is( $html->last_render->{template},
    'home/unavailable', 'render_unavailable uses the unavailable template' );
is( $html->last_render->{error},
    'home_unavailable', 'render_unavailable keeps the home_unavailable error' );

my $json =
  GPForum::Test::ResponderController->new( accept_header => 'application/json',
  );
$access->render_unavailable($json);
is( $json->last_render->{status},
    $HTTP_SERVER_ERROR, 'JSON unavailable uses HTTP 500' );
is( $json->last_render->{json}{error},
    'home_unavailable', 'JSON unavailable keeps the home_unavailable error' );
is( $json->last_render->{json}{status},
    'fail', 'JSON unavailable keeps the fail status' );

done_testing();

1;
