package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 33;
const my $HTTP_OK        => 200;
const my $HSTS_MAX_AGE   => 31_536_000;

plan tests => $EXPECTED_TESTS;

my $test = Test::Mojo->new('GPForum');

is( $test->app->sessions->samesite,
    'Lax', 'sessions use SameSite Lax by default' );
ok( !$test->app->sessions->secure,
    'development sessions do not require secure transport' );

$test->get_ok('/health/live');
$test->status_is($HTTP_OK);
$test->header_like( 'X-Request-ID' => qr/\A [[:alnum:]_.:-]+ \z/msx );
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
my $dev_headers = $test->tx->res->headers;
ok( !defined $dev_headers->header('Strict-Transport-Security'),
    'development omits HSTS' );

$test->get_ok( '/health/live' => { 'X-Request-ID' => 'request-test-1' } );
$test->header_is( 'X-Request-ID' => 'request-test-1' );

_install_cookie_route($test);
$test->get_ok('/__test/session-cookie');
$test->status_is($HTTP_OK);
my $development_cookie = _set_cookie($test);
like( $development_cookie, qr/HttpOnly/msx,
    'session cookie is HttpOnly in development' );
like( $development_cookie, qr/SameSite=Lax/msx,
    'session cookie carries SameSite=Lax' );
unlike(
    $development_cookie,
    qr/; [ ] Secure\b/msx,
    'development session cookie is not forced secure'
);

{
    local $ENV{GPFORUM_ENV}            = 'production';
    local $ENV{GPFORUM_SESSION_SECRET} = 'production-test-secret';
    local $ENV{GPFORUM_GLIFISTORE_URL} = 'tcp://127.0.0.1:7379';

    my $production = Test::Mojo->new('GPForum');
    ok( $production->app->sessions->secure,
        'production sessions require secure transport' );
    _install_cookie_route($production);
    $production->get_ok('/__test/session-cookie');
    $production->status_is($HTTP_OK);
    my $production_cookie = _set_cookie($production);
    like(
        $production_cookie,
        qr/; [ ] secure\b/imsx,
        'production session cookie is Secure'
    );
    like( $production_cookie, qr/HttpOnly/msx,
        'production session cookie is HttpOnly' );
    like( $production_cookie, qr/SameSite=Lax/msx,
        'production session cookie carries SameSite=Lax' );
    $production->header_is(
        'Strict-Transport-Security' => _hsts_header(),
        'production sends HSTS'
    );
}

{
    local $ENV{GPFORUM_ENV}            = 'staging';
    local $ENV{GPFORUM_SESSION_SECRET} = 'staging-test-secret';
    local $ENV{GPFORUM_GLIFISTORE_URL} = 'tcp://127.0.0.1:7379';

    my $staging = Test::Mojo->new('GPForum');
    ok( $staging->app->sessions->secure,
        'staging sessions require secure transport' );
    $staging->get_ok('/health/live');
    $staging->status_is($HTTP_OK);
    $staging->header_is(
        'Strict-Transport-Security' => _hsts_header(),
        'staging sends HSTS'
    );
}

sub _hsts_header {
    return 'max-age=' . $HSTS_MAX_AGE . '; includeSubDomains';
}

sub _install_cookie_route {
    my ($test_object) = @_;

    my $route = $test_object->app->routes->get('/__test/session-cookie');
    $route->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( security_cookie_probe => 'active' );
            return $controller->render( text => 'ok' );
        }
    );

    return;
}

sub _set_cookie {
    my ($test_object) = @_;

    return $test_object->tx->res->headers->header('Set-Cookie') || q{};
}

1;
