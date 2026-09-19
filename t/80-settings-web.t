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
use GPForum::Test::NotificationPreferenceStore;

our $VERSION = '0.001';

const my $HTTP_ACCEPTED  => 202;
const my $HTTP_FORBIDDEN => 403;
const my $HTTP_FOUND     => 302;
const my $HTTP_OK        => 200;

subtest 'settings require an authenticated user' => sub {
    my $test = Test::Mojo->new('GPForum');

    $test->get_ok('/settings');
    $test->status_is($HTTP_FOUND);
    $test->header_like( Location => qr{/login\z}msx );
};

subtest 'settings reject missing csrf token' => sub {
    my ($test) = _authenticated_settings_app();

    $test->post_ok( '/settings' => form => { locale => 'it' } );
    $test->status_is($HTTP_FORBIDDEN);
};

subtest 'settings persist locale theme and notification preferences' => sub {
    my ( $test, $identity_store, $preference_store ) =
      _authenticated_settings_app();

    $test->get_ok('/settings');
    $test->status_is($HTTP_OK);
    $test->text_is( 'h1' => 'Settings' );
    $test->element_exists('form[action="/settings"]');
    $test->element_exists('form.identity-form a[href="/settings"]');
    $test->element_exists('select[name="locale"] option[value="it"]');
    $test->element_exists('select[name="theme"] option[value="high_contrast"]');
    $test->element_exists('input[name="notification_in_app_enabled"][checked]');
    $test->element_exists('input[name="notification_email_enabled"][checked]');
    $test->element_exists_not(
        'input[name="notification_digest_enabled"][checked]');

    my $csrf_token = _csrf_token($test);
    $test->post_ok(
        '/settings' => form => {
            csrf_token                           => $csrf_token,
            locale                               => 'it',
            notification_digest_digest_frequency => 'weekly',
            notification_digest_enabled          => 1,
            notification_email_digest_frequency  => 'weekly',
            notification_in_app_digest_frequency => 'immediate',
            notification_in_app_enabled          => 1,
            theme                                => 'high_contrast',
        }
    );
    $test->status_is($HTTP_FOUND);
    $test->header_like( Location     => qr{/settings\z}msx );
    $test->header_like( 'Set-Cookie' => qr/gpforum_locale=it/msx );
    $test->header_like( 'Set-Cookie' => qr/gpforum_theme=high_contrast/msx );

    is( $identity_store->preferred_locale,
        'it', 'settings update persists authenticated locale' );
    is( $identity_store->preferred_theme,
        'high_contrast', 'settings update persists authenticated theme' );
    is( $preference_store->updates->[0]{user_id},
        'user-1', 'notification preferences are scoped to user' );

    my %saved = map { $_->{channel} => $_ }
      @{ $preference_store->updates->[0]{preferences} };
    is( $saved{email}{enabled}, 0,
        'unchecked email channel is saved disabled' );
    is( $saved{digest}{enabled}, 1, 'checked digest channel is saved enabled' );
    is( $saved{digest}{digest_frequency},
        'weekly', 'digest frequency is saved' );

    $test->get_ok('/settings');
    $test->status_is($HTTP_OK);
    $test->header_is( 'Content-Language' => 'it' );
    $test->text_is( 'h1' => 'Impostazioni' );
    $test->content_like(qr/Preferenze [ ] salvate[.]/msx);
    $test->element_exists(
        'html[data-theme="high_contrast"][data-color-scheme="light"]');
    $test->element_exists('select[name="locale"] option[value="it"][selected]');
    $test->element_exists(
        'select[name="theme"] option[value="high_contrast"][selected]');
    $test->element_exists('input[name="notification_digest_enabled"][checked]');
    $test->element_exists_not(
        'input[name="notification_email_enabled"][checked]');
};

done_testing();

sub _authenticated_settings_app {
    my $identity_store   = GPForum::Test::IdentityStore->new;
    my $preference_store = GPForum::Test::NotificationPreferenceStore->new;
    my $test             = Test::Mojo->new('GPForum');
    $test->app->helper( gp_identity_store => sub { return $identity_store; } );
    $test->app->helper(
        gp_identity_security_audit => sub {
            return GPForum::Test::IdentitySecurityAudit->new;
        }
    );
    $test->app->helper(
        gp_notification_preference_store => sub {
            return $preference_store;
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

    return ( $test, $identity_store, $preference_store );
}

sub _csrf_token {
    my ($test_object) = @_;

    my $body = $test_object->tx->res->body;
    my ($token) = $body =~ /name="csrf_token" [^>]+ value="([^"]+)"/msx;

    return $token;
}

1;
