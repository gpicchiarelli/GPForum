# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::CommandIdempotency;
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
    $test->element_exists_not('form.theme-form input[name="command_id"]');
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
    $test->text_is( 'p.flash--success[role="status"]' => 'Theme updated' );
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
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
        }
    );
    $test->app->helper(
        gp_identity_security_audit => sub {
            return GPForum::Test::IdentitySecurityAudit->new;
        }
    );

    $test->get_ok('/login');
    my $login_token      = _csrf_token($test);
    my $login_command_id = _command_id($test);
    $test->post_ok(
        '/login' => form => {
            command_id => $login_command_id,
            csrf_token => $login_token,
            identifier => 'giacomo_forum',
            password   => 'correct horse battery staple',
        }
    );
    $test->status_is($HTTP_ACCEPTED);

    $test->get_ok('/login');
    $test->element_exists('form.theme-form input[name="command_id"]');
    my $theme_token      = _csrf_token($test);
    my $theme_command_id = _command_id( $test, '/theme' );
    $test->post_ok(
        '/theme' => form => {
            command_id => $theme_command_id,
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
    $test->post_ok(
        '/logout' => form => {
            command_id => _command_id($test),
            csrf_token => $logout_token,
        }
    );
    $test->status_is($HTTP_ACCEPTED);

    $test->get_ok('/login');
    $test->status_is($HTTP_OK);
    $test->element_exists(
        'html[data-theme="high_contrast"][data-color-scheme="light"]');

    my $second_login_token      = _csrf_token($test);
    my $second_login_command_id = _command_id($test);
    $test->post_ok(
        '/login' => form => {
            command_id => $second_login_command_id,
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

sub _command_id {
    my ( $test_object, $form_action ) = @_;

    my $body = $test_object->tx->res->body;
    if ($form_action) {
        return _command_id_in_form( $body, $form_action );
    }

    my ($command_id) = $body =~ /name="command_id" [^>]+ value="([^"]+)"/msx;

    return $command_id;
}

sub _command_id_in_form {
    my ( $body, $form_action ) = @_;

    const my $FORM_SNIPPET => 800;
    my $quote  = q{"};
    my $marker = 'action=' . $quote . $form_action . $quote;
    my $start  = index $body, $marker;
    if ( $start < 0 ) {
        return;
    }

    my $chunk        = substr $body, $start, $FORM_SNIPPET;
    my ($command_id) = $chunk =~ /name="command_id" [^>]+ value="([^"]+)"/msx;

    return $command_id;
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
