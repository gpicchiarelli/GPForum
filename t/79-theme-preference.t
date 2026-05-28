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

subtest 'guest theme selector persists in a cookie' => sub {
    my $test = Test::Mojo->new('GPForum');

    $test->get_ok('/login');
    $test->status_is($HTTP_OK);
    $test->element_exists('form.theme-form[action="/theme"]');
    $test->element_exists('select[name="theme"] option[value="dark"]');
    $test->element_exists(
        'select[name="theme"] option[value="default"][selected]');

    my $csrf_token = _csrf_token($test);
    $test->post_ok(
        '/theme' => form => {
            csrf_token => $csrf_token,
            return_to  => '/login',
            theme      => 'dark',
        }
    );
    $test->status_is($HTTP_FOUND);
    $test->header_like( Location     => qr{\A/login\z}msx );
    $test->header_like( 'Set-Cookie' => qr/gpforum_theme=dark/msx );

    $test->get_ok('/login');
    $test->status_is($HTTP_OK);
    $test->element_exists('html[data-theme="dark"][data-color-scheme="dark"]');
    $test->element_exists(
        'select[name="theme"] option[value="dark"][selected]');
};

subtest 'unsupported theme inputs fall back safely' => sub {
    my $test = Test::Mojo->new('GPForum');

    $test->get_ok('/login');
    my $csrf_token = _csrf_token($test);
    $test->post_ok(
        '/theme' => form => {
            csrf_token => $csrf_token,
            return_to  => '/login',
            theme      => 'neon',
        }
    );
    $test->status_is($HTTP_FOUND);
    $test->header_like( 'Set-Cookie' => qr/gpforum_theme=default/msx );

    $test->get_ok('/login');
    $test->status_is($HTTP_OK);
    $test->element_exists(
        'html[data-theme="default"][data-color-scheme="light"]');
    $test->element_exists(
        'select[name="theme"] option[value="default"][selected]');
};

subtest 'authenticated theme persists on profile and survives logout' => sub {
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
    my $theme_token = _csrf_token($test);
    $test->post_ok(
        '/theme' => form => {
            csrf_token => $theme_token,
            return_to  => '/login',
            theme      => 'high_contrast',
        }
    );
    $test->status_is($HTTP_FOUND);
    is( $store->preferred_theme,
        'high_contrast', 'authenticated theme is persisted' );
    is( $store->theme_updates->[0]{user_id},
        'user-1', 'theme update is scoped to authenticated user' );

    $test->get_ok('/__test/session-state');
    $test->json_is( '/preferred_theme' => 'high_contrast' );

    $test->get_ok('/login');
    $test->status_is($HTTP_OK);
    $test->element_exists(
        'html[data-theme="high_contrast"][data-color-scheme="light"]');

    my $logout_token = _csrf_token($test);
    $test->post_ok( '/logout' => form => { csrf_token => $logout_token } );
    $test->status_is($HTTP_ACCEPTED);

    $test->get_ok('/login');
    $test->status_is($HTTP_OK);
    $test->element_exists(
        'html[data-theme="high_contrast"][data-color-scheme="light"]');

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
    $test->json_is( '/preferred_theme' => 'high_contrast' );
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
                    preferred_theme => $controller->session('preferred_theme'),
                    session_id      => $controller->session('session_id'),
                    user_id         => $controller->session('user_id'),
                }
            );
        }
    );

    return;
}

1;
