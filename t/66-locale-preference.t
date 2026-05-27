package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::IdentitySecurityAudit;
use GPForum::Test::IdentityStore;

our $VERSION = '0.001';

const my $HTTP_ACCEPTED => 202;
const my $HTTP_FOUND    => 302;
const my $HTTP_OK       => 200;

subtest 'guest locale selector persists in a cookie' => sub {
    my $test = Test::Mojo->new('GPForum');

    $test->get_ok( '/login' => { 'Accept-Language' => 'en' } );
    $test->status_is($HTTP_OK);
    $test->header_is( 'Content-Language' => 'en' );
    $test->text_is( 'h1' => 'Login' );
    $test->element_exists('form.locale-form[action="/locale"]');
    $test->element_exists('select[name="locale"] option[value="it"]');

    my $csrf_token = _csrf_token($test);
    $test->post_ok(
        '/locale' => form => {
            csrf_token => $csrf_token,
            locale     => 'it',
            return_to  => '/login',
        }
    );
    $test->status_is($HTTP_FOUND);
    $test->header_like( Location     => qr{\A/login\z}msx );
    $test->header_like( 'Set-Cookie' => qr/gpforum_locale=it/msx );

    $test->get_ok( '/login' => { 'Accept-Language' => 'en' } );
    $test->status_is($HTTP_OK);
    $test->header_is( 'Content-Language' => 'it' );
    $test->text_is( 'h1' => 'Accesso' );
    $test->element_exists('select[name="locale"] option[value="it"][selected]');
};

subtest 'unsupported locale inputs fall back safely' => sub {
    my $test = Test::Mojo->new('GPForum');

    $test->get_ok(
        '/login' => {
            'Accept-Language' => 'en',
            Cookie            => 'gpforum_locale=zz',
        }
    );
    $test->status_is($HTTP_OK);
    $test->header_is( 'Content-Language' => 'en' );
    $test->text_is( 'h1' => 'Login' );
};

subtest 'authenticated locale persists on profile and survives logout' => sub {
    my $store = GPForum::Test::IdentityStore->new;
    my $test  = Test::Mojo->new('GPForum');
    _install_session_state_route($test);
    $test->app->helper( gp_identity_store => sub { return $store; } );
    $test->app->helper(
        gp_identity_security_audit => sub {
            return GPForum::Test::IdentitySecurityAudit->new;
        }
    );

    $test->get_ok('/login');
    my $login_token = _csrf_token($test);
    $test->post_ok(
        '/login' => form => {
            csrf_token => $login_token,
            identifier => 'giacomo_forum',
            password   => 'correct horse battery staple',
        }
    );
    $test->status_is($HTTP_ACCEPTED);

    $test->get_ok('/login');
    my $locale_token = _csrf_token($test);
    $test->post_ok(
        '/locale' => form => {
            csrf_token => $locale_token,
            locale     => 'it',
            return_to  => '/login',
        }
    );
    $test->status_is($HTTP_FOUND);
    is( $store->preferred_locale, 'it', 'authenticated locale is persisted' );
    is( $store->locale_updates->[0]{user_id},
        'user-1', 'locale update is scoped to authenticated user' );

    $test->get_ok('/__test/session-state');
    $test->json_is( '/preferred_locale' => 'it' );

    $test->get_ok( '/login' => { 'Accept-Language' => 'en' } );
    $test->status_is($HTTP_OK);
    $test->header_is( 'Content-Language' => 'it' );
    $test->text_is( 'h1' => 'Accesso' );

    my $logout_token = _csrf_token($test);
    $test->post_ok( '/logout' => form => { csrf_token => $logout_token } );
    $test->status_is($HTTP_ACCEPTED);

    $test->get_ok( '/login' => { 'Accept-Language' => 'en' } );
    $test->status_is($HTTP_OK);
    $test->header_is( 'Content-Language' => 'it' );

    my $second_login_token = _csrf_token($test);
    $test->post_ok(
        '/login' => form => {
            csrf_token => $second_login_token,
            identifier => 'giacomo_forum',
            password   => 'correct horse battery staple',
        }
    );
    $test->status_is($HTTP_ACCEPTED);
    $test->get_ok('/__test/session-state');
    $test->json_is( '/preferred_locale' => 'it' );
};

done_testing();

sub _csrf_token {
    my ($test_object) = @_;

    my $body = $test_object->tx->res->body;
    my ($token) = $body =~ /name="csrf_token" [^>]+ value="([^"]+)"/msx;

    return $token;
}

sub _install_session_state_route {
    my ($test_object) = @_;

    $test_object->app->routes->get('/__test/session-state')->to(
        cb => sub {
            my ($controller) = @_;

            return $controller->render(
                json => {
                    preferred_locale =>
                      $controller->session('preferred_locale'),
                    session_id => $controller->session('session_id'),
                    user_id    => $controller->session('user_id'),
                }
            );
        }
    );

    return;
}

1;
