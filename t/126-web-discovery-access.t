# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Test::DiscoveryController;
use GPForum::Web::DiscoveryAccess;
use Test::More;

our $VERSION = '0.001';

const my $HTTP_OK              => 200;
const my $DEFAULT_FEED_LIMIT   => 25;
const my $DEFAULT_SITEMAP_ROWS => 100;
const my $REQUESTED_FEED_LIMIT => 10;

my $access = GPForum::Web::DiscoveryAccess->new;
is( $access->sitemap_limit,
    $DEFAULT_SITEMAP_ROWS, 'sitemap_limit keeps the default sitemap rows' );
is( $access->feed_limit(undef),
    $DEFAULT_FEED_LIMIT, 'feed_limit defaults a missing requested limit' );
is( $access->feed_limit($REQUESTED_FEED_LIMIT),
    $REQUESTED_FEED_LIMIT, 'feed_limit keeps an explicit requested limit' );
is( $access->feed_limit(0),
    $DEFAULT_FEED_LIMIT, 'feed_limit defaults a zero requested limit' );

my $controller = GPForum::Test::DiscoveryController->new;
my $document   = {
    content_type => 'text/plain; charset=utf-8',
    data         => 'User-agent: *',
    format       => 'txt',
    status       => $HTTP_OK,
};
$access->render_document( $controller, $document );
is(
    $controller->last_content_type,
    'text/plain; charset=utf-8',
    'render_document sets the document content type'
);
is(
    $controller->last_render->{data},
    'User-agent: *',
    'render_document renders document data'
);
is( $controller->last_render->{format},
    'txt', 'render_document keeps the document format' );
is( $controller->last_render->{status},
    $HTTP_OK, 'render_document keeps an explicit status' );

my $without_status = { %{$document} };
delete $without_status->{status};
$access->render_document( $controller, $without_status );
is( $controller->last_render->{status},
    $HTTP_OK, 'render_document defaults a missing status to HTTP 200' );

done_testing();

1;
