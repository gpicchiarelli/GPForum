# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use IO::Uncompress::Gunzip qw(gunzip);
use Test::Mojo;
use Test::More;

use lib 'lib';

our $VERSION = '0.001';

const my $HTTP_OK => 200;
const my $REPEAT  => 200;

# A page is gzipped for a client that accepts it, with the headers
# Mojolicious writes for one: Vary on every response large enough to be
# compressed, Content-Encoding on the compressed ones. The renderer's own
# compression is off, so a page is not encoded twice.
my $test = Test::Mojo->new('GPForum');
my $app  = $test->app;
ok( !$app->renderer->compress, q{the renderer's compression is off} );

my $page = join q{},
  map { "<p>paragraph $_ of a page worth compressing</p>\n" } 1 .. $REPEAT;
my $short = '<p>short</p>';
$app->routes->get('/gzip-page')
  ->to( cb => sub ($c) { $c->render( text => $page ) } );
$app->routes->get('/gzip-short')
  ->to( cb => sub ($c) { $c->render( text => $short ) } );
$app->routes->get('/gzip-encoded')->to(
    cb => sub ($c) {
        $c->res->headers->content_encoding('identity');
        $c->render( text => $page );
    }
);

# Test::Mojo's client accepts gzip, decodes the body on the way back and
# drops the encoding header with it.
$test->get_ok('/gzip-page');
$test->status_is($HTTP_OK);
$test->header_like( Vary => qr/Accept-Encoding/msx );
$test->content_is( $page, 'the page gunzips to what was rendered' );

my $raw = $test->ua->build_tx( GET => '/gzip-page' );
$raw->req->headers->accept_encoding('gzip');
$raw->res->content->auto_decompress(0);
$raw = $test->ua->start($raw);
is( $raw->res->headers->content_encoding, 'gzip', 'Content-Encoding: gzip' );
my $gunzipped;
gunzip( \( $raw->res->body ) => \$gunzipped );
is( $gunzipped, $page, 'the bytes on the wire are gzip' );
cmp_ok(
    length $raw->res->body,
    '<',
    length($page) / 2,
    'and fewer than half the page'
);

$test->get_ok( '/gzip-page' => { 'Accept-Encoding' => 'identity' } );
$test->status_is($HTTP_OK);
my $plain = $test->tx->res->headers;
ok( !$plain->content_encoding,
    'a client that does not accept gzip gets the page as is' );
$test->header_like( Vary => qr/Accept-Encoding/msx, 'and Vary still' );
$test->content_is($page);

$test->get_ok('/gzip-short');
my $short_headers = $test->tx->res->headers;
ok( !$short_headers->content_encoding, 'a short response is not compressed' );
ok( !$short_headers->vary,             'and does not vary' );
$test->content_is($short);

$test->get_ok('/gzip-encoded');
$test->header_is(
    'Content-Encoding' => 'identity',
    'a response encoded already is left alone'
);
$test->content_is($page);

done_testing();

1;
