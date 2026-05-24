package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 13;
const my $HTTP_OK        => 200;

plan tests => $EXPECTED_TESTS;

my $test = Test::Mojo->new('GPForum');

is( $test->app->sessions->samesite,
    'Lax', 'sessions use SameSite Lax by default' );
ok( !$test->app->sessions->secure,
    'development sessions do not require secure transport' );

$test->get_ok('/health/live');
$test->status_is($HTTP_OK);
$test->header_is( 'X-Content-Type-Options' => 'nosniff' );
$test->header_is( 'X-Frame-Options'        => 'DENY' );
$test->header_is( 'Referrer-Policy' => 'strict-origin-when-cross-origin' );
$test->header_like( 'Permissions-Policy' => qr/camera=[(][)]/msx );
$test->header_like( 'Permissions-Policy' => qr/microphone=[(][)]/msx );
$test->header_like(
    'Content-Security-Policy' => qr/default-src [ ] 'self'/msx );
$test->header_like( 'Content-Security-Policy' => qr/base-uri [ ] 'self'/msx );
$test->header_like(
    'Content-Security-Policy' => qr/form-action [ ] 'self'/msx );
$test->header_like(
    'Content-Security-Policy' => qr/frame-ancestors [ ] 'none'/msx );

1;
