package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;
use Test::Mojo;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::AllowLimiter;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::IdentityStore;
use GPForum::Test::DenyLimiter;
use GPForum::Test::IdentitySecurityAudit;

our $VERSION = '0.001';

const my $EXPECTED_TESTS    => 106;
const my $HTTP_OK           => 200;
const my $HTTP_ACCEPTED     => 202;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_FOUND        => 302;
const my $HTTP_NOT_FOUND    => 404;
const my $HTTP_TOO_MANY     => 429;
const my $HTTP_UNAUTHORIZED => 401;

plan tests => $EXPECTED_TESTS;

my $test  = Test::Mojo->new('GPForum');
my $audit = GPForum::Test::IdentitySecurityAudit->new;
_install_session_state_routes($test);
$test->app->helper(
    gp_identity_store => sub {
        return GPForum::Test::IdentityStore->new;
    }
);
$test->app->helper(
    gp_profile_reader => sub {
        return GPForum::Test::IdentityStore->new;
    }
);
$test->app->helper( gp_identity_security_audit => sub { return $audit; } );
$test->app->helper(
    gp_command_idempotency => sub {
        return GPForum::Test::CommandIdempotency->new;
    }
);
$test->app->helper(
    gp_rate_limiter => sub {
        return GPForum::Test::AllowLimiter->new;
    }
);

$test->get_ok('/register');
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Create account' );
$test->element_exists('input[name="csrf_token"]');
$test->element_exists('input[name="command_id"]');
$test->element_exists('input[name="username"]');

my $register_token      = _csrf_token($test);
my $register_command_id = _command_id($test);

$test->post_ok('/register');
$test->status_is($HTTP_FORBIDDEN);
$test->content_like(qr/Bad [ ] CSRF [ ] token/msx);

$test->post_ok(
    '/register' => form => {
        command_id   => $register_command_id,
        csrf_token   => $register_token,
        username     => 'gp',
        display_name => q{},
        email        => 'bad-email',
        password     => 'short',
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->content_like(qr/username [ ] length [ ] is [ ] invalid/msx);
$test->content_like(qr/display [ ] name [ ] is [ ] required/msx);
$test->content_like(qr/email [ ] format [ ] is [ ] invalid/msx);

$test->get_ok('/register');
my $fresh_register_token      = _csrf_token($test);
my $fresh_register_command_id = _command_id($test);

$test->post_ok(
    '/register' => form => {
        command_id   => $fresh_register_command_id,
        csrf_token   => $fresh_register_token,
        username     => 'Giacomo_Forum',
        display_name => 'Giacomo Picchiarelli',
        email        => 'GIACOMO@example.test',
        password     => 'correct horse battery staple',
    }
);
$test->status_is($HTTP_ACCEPTED);
$test->text_is( 'h1' => 'Registration accepted' );
$test->content_like(qr/giacomo_forum/msx);

$test->get_ok('/login');
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Login' );
$test->element_exists('input[name="csrf_token"]');
$test->element_exists('input[name="command_id"]');
$test->element_exists('a[href="/password/reset"]');
$test->content_like(qr/Forgot [ ] password[?]/msx);

my $login_token      = _csrf_token($test);
my $login_command_id = _command_id($test);

$test->post_ok('/login');
$test->status_is($HTTP_FORBIDDEN);

$test->post_ok(
    '/login' => form => {
        command_id => $login_command_id,
        csrf_token => $login_token,
        identifier => q{},
        password   => q{},
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->content_like(qr/identifier [ ] is [ ] required/msx);
$test->content_like(qr/password [ ] is [ ] required/msx);

$test->get_ok('/__test/fixate-session');
$test->status_is($HTTP_OK);
$test->get_ok('/login');
my $fresh_login_token      = _csrf_token($test);
my $fresh_login_command_id = _command_id($test);

$test->post_ok(
    '/login' => form => {
        command_id => $fresh_login_command_id,
        csrf_token => $fresh_login_token,
        identifier => 'giacomo_forum',
        password   => 'correct horse battery staple',
    }
);
$test->status_is($HTTP_ACCEPTED);
$test->text_is( 'h1' => 'Login request accepted' );
$test->get_ok('/__test/session-state');
$test->status_is($HTTP_OK);
$test->json_is( '/user_id'    => 'user-1' );
$test->json_is( '/session_id' => 'session-1' );
$test->json_has('/session_expires_at_epoch');
$test->json_has('/login_rotation');
isnt( $test->tx->res->json->{login_rotation},
    'fixed-rotation', 'login rotates fixed session marker' );
is( scalar @{ $audit->records }, 1, 'login request is audited' );
is( $audit->records->[0]{method},
    'record_login_request', 'login audit method is explicit' );

my $invalid_login_test = Test::Mojo->new('GPForum');
$invalid_login_test->app->helper(
    gp_identity_store => sub {
        return GPForum::Test::IdentityStore->new( invalid_login => 1 );
    }
);
$invalid_login_test->app->helper(
    gp_identity_security_audit => sub {
        return GPForum::Test::IdentitySecurityAudit->new;
    }
);
$invalid_login_test->app->helper(
    gp_rate_limiter => sub {
        return GPForum::Test::AllowLimiter->new;
    }
);
$invalid_login_test->app->helper(
    gp_command_idempotency => sub {
        return GPForum::Test::CommandIdempotency->new;
    }
);
$invalid_login_test->get_ok('/login');
my $invalid_login_token      = _csrf_token($invalid_login_test);
my $invalid_login_command_id = _command_id($invalid_login_test);
$invalid_login_test->post_ok(
    '/login' => form => {
        command_id => $invalid_login_command_id,
        csrf_token => $invalid_login_token,
        identifier => 'giacomo_forum',
        password   => 'wrong password',
    }
);
$invalid_login_test->status_is($HTTP_UNAUTHORIZED);
$invalid_login_test->content_like(
    qr/login [ ] request [ ] could [ ] not [ ] be [ ] accepted/msx);
$invalid_login_test->content_unlike(qr/invalid_credentials/msx);

subtest 'password reset web flow is csrf protected and rate limited' => sub {
    my $reset_store = GPForum::Test::IdentityStore->new;
    my $reset_test  = Test::Mojo->new('GPForum');
    $reset_test->app->helper(
        gp_identity_store => sub { return $reset_store; } );
    $reset_test->app->helper(
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
        }
    );
    $reset_test->app->helper(
        gp_identity_security_audit => sub {
            return GPForum::Test::IdentitySecurityAudit->new;
        }
    );
    $reset_test->app->helper(
        gp_rate_limiter => sub {
            return GPForum::Test::AllowLimiter->new;
        }
    );

    $reset_test->get_ok('/password/reset');
    $reset_test->status_is($HTTP_OK);
    $reset_test->text_is( 'h1' => 'Reset password' );
    $reset_test->element_exists('input[name="csrf_token"]');
    $reset_test->element_exists('input[name="command_id"]');

    $reset_test->post_ok('/password/reset');
    $reset_test->status_is($HTTP_FORBIDDEN);

    $reset_test->get_ok('/password/reset');
    my $reset_token      = _csrf_token($reset_test);
    my $reset_command_id = _command_id($reset_test);
    $reset_test->post_ok(
        '/password/reset' => form => {
            command_id => $reset_command_id,
            csrf_token => $reset_token,
            identifier => 'giacomo@example.test',
        }
    );
    $reset_test->status_is($HTTP_ACCEPTED);
    $reset_test->text_is( 'h1' => 'Password reset requested' );
    is( $reset_store->lifecycle_calls->[0]{method},
        'request_password_reset', 'reset request reaches identity store' );

    $reset_test->get_ok('/password/reset/reset-token');
    $reset_test->status_is($HTTP_OK);
    $reset_test->element_exists('input[name="token"][value="reset-token"]');
    $reset_test->element_exists('input[name="command_id"]');

    $reset_test->post_ok('/password/reset/complete');
    $reset_test->status_is($HTTP_FORBIDDEN);

    $reset_test->get_ok('/password/reset/reset-token');
    my $complete_token      = _csrf_token($reset_test);
    my $complete_command_id = _command_id($reset_test);
    $reset_test->post_ok(
        '/password/reset/complete' => form => {
            command_id => $complete_command_id,
            csrf_token => $complete_token,
            password   => 'new correct horse battery',
            token      => 'reset-token',
        }
    );
    $reset_test->status_is($HTTP_ACCEPTED);
    $reset_test->text_is( 'h1' => 'Password changed' );
    is( $reset_store->lifecycle_calls->[1]{method},
        'reset_password', 'reset completion reaches identity store' );

    my $limited = Test::Mojo->new('GPForum');
    $limited->app->helper(
        gp_identity_store => sub { return GPForum::Test::IdentityStore->new; }
    );
    $limited->app->helper(
        gp_rate_limiter => sub { return GPForum::Test::DenyLimiter->new; } );
    $limited->get_ok('/password/reset');
    my $limited_token = _csrf_token($limited);
    $limited->post_ok(
        '/password/reset' => form => {
            csrf_token => $limited_token,
            identifier => 'limited@example.test',
        }
    );
    $limited->status_is($HTTP_TOO_MANY);
};

subtest 'authenticated password and email changes require csrf' => sub {
    my $settings_store = GPForum::Test::IdentityStore->new;
    my $settings_test  = Test::Mojo->new('GPForum');
    _install_session_state_routes($settings_test);
    $settings_test->app->helper(
        gp_identity_store => sub { return $settings_store; } );
    $settings_test->app->helper(
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
        }
    );
    $settings_test->app->helper(
        gp_rate_limiter => sub {
            return GPForum::Test::AllowLimiter->new;
        }
    );

    $settings_test->get_ok('/__test/fixate-session');
    $settings_test->status_is($HTTP_OK);

    $settings_test->post_ok('/settings/password');
    $settings_test->status_is($HTTP_FORBIDDEN);

    $settings_test->get_ok('/login');
    my $settings_token = _csrf_token($settings_test);
    $settings_test->post_ok(
        '/settings/password' => form => {
            command_id       => 'password-change-1',
            csrf_token       => $settings_token,
            current_password => 'correct horse battery staple',
            new_password     => 'new correct horse battery',
        }
    );
    $settings_test->status_is($HTTP_FOUND);
    is( $settings_store->lifecycle_calls->[0]{method},
        'change_password', 'password change reaches identity store' );

    $settings_test->get_ok('/login');
    my $email_token = _csrf_token($settings_test);
    $settings_test->post_ok(
        '/settings/email' => form => {
            command_id => 'email-change-1',
            csrf_token => $email_token,
            email      => 'new@example.test',
        }
    );
    $settings_test->status_is($HTTP_FOUND);
    is( $settings_store->lifecycle_calls->[1]{method},
        'request_email_change', 'email change reaches identity store' );
};

subtest 'email confirmation consumes token through csrf protected post' => sub {
    my $confirm_store = GPForum::Test::IdentityStore->new;
    my $confirm_test  = Test::Mojo->new('GPForum');
    $confirm_test->app->helper(
        gp_identity_store => sub { return $confirm_store; } );
    $confirm_test->app->helper(
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
        }
    );
    $confirm_test->app->helper(
        gp_rate_limiter => sub {
            return GPForum::Test::AllowLimiter->new;
        }
    );

    $confirm_test->get_ok('/email/confirm/email-token');
    $confirm_test->status_is($HTTP_OK);
    $confirm_test->text_is( 'h1' => 'Confirm email change' );
    $confirm_test->element_exists('input[name="token"][value="email-token"]');
    $confirm_test->element_exists('input[name="command_id"]');

    $confirm_test->post_ok('/email/confirm');
    $confirm_test->status_is($HTTP_FORBIDDEN);

    $confirm_test->get_ok('/email/confirm/email-token');
    my $confirm_token      = _csrf_token($confirm_test);
    my $confirm_command_id = _command_id($confirm_test);
    $confirm_test->post_ok(
        '/email/confirm' => form => {
            command_id => $confirm_command_id,
            csrf_token => $confirm_token,
            token      => 'email-token',
        }
    );
    $confirm_test->status_is($HTTP_ACCEPTED);
    $confirm_test->text_is( 'h1' => 'Email confirmed' );
    is( $confirm_store->lifecycle_calls->[0]{method},
        'confirm_email_change', 'email confirmation reaches identity store' );
};

$test->post_ok('/logout');
$test->status_is($HTTP_FORBIDDEN);

$test->get_ok('/login');
my $logout_token      = _csrf_token($test);
my $logout_command_id = _command_id($test);

$test->post_ok(
    '/logout' => form => {
        command_id => $logout_command_id,
        csrf_token => $logout_token,
    }
);
$test->status_is($HTTP_ACCEPTED);
$test->text_is( 'h1' => 'Logout request accepted' );
is( scalar @{ $audit->records }, 2, 'logout request is audited' );
is( $audit->records->[1]{method},
    'record_logout_request', 'logout audit method is explicit' );

$test->get_ok('/login');
my $idempotent_logout_token      = _csrf_token($test);
my $idempotent_logout_command_id = _command_id($test);
$test->post_ok(
    '/logout' => form => {
        command_id => $idempotent_logout_command_id,
        csrf_token => $idempotent_logout_token,
    }
);
$test->status_is($HTTP_ACCEPTED);

my $invalid_session_test = Test::Mojo->new('GPForum');
_install_session_state_routes($invalid_session_test);
$invalid_session_test->app->helper(
    gp_identity_store => sub {
        return GPForum::Test::IdentityStore->new( invalid_session => 1 );
    }
);
$invalid_session_test->get_ok('/__test/fixate-session');
$invalid_session_test->status_is($HTTP_OK);
$invalid_session_test->get_ok('/__test/session-state');
$invalid_session_test->status_is($HTTP_OK);
$invalid_session_test->json_is( '/user_id'    => undef );
$invalid_session_test->json_is( '/session_id' => undef );

$test->get_ok('/u/giacomo_forum');
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Giacomo Picchiarelli' );
$test->content_like(qr/[@]giacomo_forum/msx);
$test->element_exists('dl[aria-label="Contributor summary"]');
$test->content_like(qr/Public [ ] contributions/msx);
$test->content_like(qr/Trusted [ ] contributor/msx);
$test->content_like(qr/Reputation [ ] score/msx);
$test->element_exists(
    'ol[aria-label="Public discussions by this contributor"]');
$test->element_exists('a[href="/t/thread-1"]');
$test->element_exists(
    'ol[aria-label="Recent public replies by this contributor"]');
$test->element_exists('a[href="/t/thread-1#post-post-2"]');
$test->element_exists('nav[aria-label="Profile activity pagination"]');
$test->content_unlike(qr/GIACOMO[@]example[.]test/msx);

$test->get_ok('/u/missing');
$test->status_is($HTTP_NOT_FOUND);
$test->text_is( 'h1' => 'Profile not found' );

$test->get_ok('/u/missing?format=json');
$test->status_is($HTTP_NOT_FOUND);
$test->json_is( '/status' => 'not_found' );

my $duplicate_test = Test::Mojo->new('GPForum');
$duplicate_test->app->helper(
    gp_identity_store => sub {
        return GPForum::Test::IdentityStore->new( duplicate => 1 );
    }
);
$duplicate_test->app->helper(
    gp_identity_security_audit => sub {
        return GPForum::Test::IdentitySecurityAudit->new;
    }
);
$duplicate_test->app->helper(
    gp_rate_limiter => sub {
        return GPForum::Test::AllowLimiter->new;
    }
);
$duplicate_test->app->helper(
    gp_command_idempotency => sub {
        return GPForum::Test::CommandIdempotency->new;
    }
);
$duplicate_test->get_ok('/register');
my $duplicate_token      = _csrf_token($duplicate_test);
my $duplicate_command_id = _command_id($duplicate_test);
$duplicate_test->post_ok(
    '/register' => form => {
        command_id   => $duplicate_command_id,
        csrf_token   => $duplicate_token,
        username     => 'Existing_User',
        display_name => 'Existing User',
        email        => 'existing@example.test',
        password     => 'correct horse battery staple',
    }
);
$duplicate_test->status_is($HTTP_BAD_REQUEST);
$duplicate_test->content_like(
    qr/registration [ ] request [ ] could [ ] not [ ] be [ ] accepted/msx);
$duplicate_test->content_unlike(qr/username [ ] is [ ] already/msx);
$duplicate_test->content_unlike(qr/email [ ] is [ ] already/msx);

$test->app->helper(
    gp_rate_limiter => sub { return GPForum::Test::DenyLimiter->new; } );
$test->get_ok('/register');
my $limited_register_token      = _csrf_token($test);
my $limited_register_command_id = _command_id($test);
$test->post_ok(
    '/register' => form => {
        command_id   => $limited_register_command_id,
        csrf_token   => $limited_register_token,
        username     => 'limited_user',
        display_name => 'Limited User',
        email        => 'limited@example.test',
        password     => 'correct horse battery staple',
    }
);
$test->status_is($HTTP_TOO_MANY);
$test->content_like(qr/Too [ ] many [ ] requests/msx);

$test->get_ok('/login');
my $limited_login_token      = _csrf_token($test);
my $limited_login_command_id = _command_id($test);
$test->post_ok(
    '/login' => form => {
        command_id => $limited_login_command_id,
        csrf_token => $limited_login_token,
        identifier => 'limited_user',
        password   => 'correct horse battery staple',
    }
);
$test->status_is($HTTP_TOO_MANY);
$test->content_like(qr/Too [ ] many [ ] requests/msx);

sub _csrf_token {
    my ($test_object) = @_;

    my $body = $test_object->tx->res->body;
    my ($token) = $body =~ /name="csrf_token" [^>]+ value="([^"]+)"/msx;

    return $token;
}

sub _command_id {
    my ($test_object) = @_;

    my $body = $test_object->tx->res->body;
    my ($command_id) = $body =~ /name="command_id" [^>]+ value="([^"]+)"/msx;

    return $command_id;
}

sub _install_session_state_routes {
    my ($test_object) = @_;

    $test_object->app->routes->get('/__test/fixate-session')->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session(
                login_rotation           => 'fixed-rotation',
                session_expires_at_epoch => time + 3_600,
                session_id               => 'fixed-session',
                user_id                  => 'attacker',
            );
            return $controller->render( json => { ok => 1 } );
        }
    );
    $test_object->app->routes->get('/__test/session-state')->to(
        cb => sub {
            my ($controller) = @_;

            return $controller->render(
                json => {
                    login_rotation => $controller->session('login_rotation'),
                    session_expires_at_epoch =>
                      $controller->session('session_expires_at_epoch'),
                    session_id => $controller->session('session_id'),
                    user_id    => $controller->session('user_id'),
                }
            );
        }
    );

    return;
}

1;
