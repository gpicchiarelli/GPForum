package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;
use Test::Mojo;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::IdentityStore;
use GPForum::Test::DenyLimiter;
use GPForum::Test::IdentitySecurityAudit;

our $VERSION = '0.001';

const my $EXPECTED_TESTS   => 72;
const my $HTTP_OK          => 200;
const my $HTTP_ACCEPTED    => 202;
const my $HTTP_BAD_REQUEST => 400;
const my $HTTP_FORBIDDEN   => 403;
const my $HTTP_NOT_FOUND   => 404;
const my $HTTP_TOO_MANY    => 429;

plan tests => $EXPECTED_TESTS;

my $test  = Test::Mojo->new('GPForum');
my $audit = GPForum::Test::IdentitySecurityAudit->new;
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

$test->get_ok('/register');
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Create account' );
$test->element_exists('input[name="csrf_token"]');
$test->element_exists('input[name="username"]');

my $register_token = _csrf_token($test);

$test->post_ok('/register');
$test->status_is($HTTP_FORBIDDEN);
$test->content_like(qr/Bad [ ] CSRF [ ] token/msx);

$test->post_ok(
    '/register' => form => {
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
my $fresh_register_token = _csrf_token($test);

$test->post_ok(
    '/register' => form => {
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

my $login_token = _csrf_token($test);

$test->post_ok('/login');
$test->status_is($HTTP_FORBIDDEN);

$test->post_ok(
    '/login' => form => {
        csrf_token => $login_token,
        identifier => q{},
        password   => q{},
    }
);
$test->status_is($HTTP_BAD_REQUEST);
$test->content_like(qr/identifier [ ] is [ ] required/msx);
$test->content_like(qr/password [ ] is [ ] required/msx);

$test->get_ok('/login');
my $fresh_login_token = _csrf_token($test);

$test->post_ok(
    '/login' => form => {
        csrf_token => $fresh_login_token,
        identifier => 'giacomo_forum',
        password   => 'correct horse battery staple',
    }
);
$test->status_is($HTTP_ACCEPTED);
$test->text_is( 'h1' => 'Login request accepted' );
is( scalar @{ $audit->records }, 1, 'login request is audited' );
is( $audit->records->[0]{method},
    'record_login_request', 'login audit method is explicit' );

$test->post_ok('/logout');
$test->status_is($HTTP_FORBIDDEN);

$test->get_ok('/login');
my $logout_token = _csrf_token($test);

$test->post_ok( '/logout' => form => { csrf_token => $logout_token } );
$test->status_is($HTTP_ACCEPTED);
$test->text_is( 'h1' => 'Logout request accepted' );
is( scalar @{ $audit->records }, 2, 'logout request is audited' );
is( $audit->records->[1]{method},
    'record_logout_request', 'logout audit method is explicit' );

$test->get_ok('/u/giacomo_forum');
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Giacomo Picchiarelli' );
$test->content_like(qr/[@]giacomo_forum/msx);
$test->element_exists('dl[aria-label="Contributor summary"]');
$test->content_like(qr/Reputation [ ] score/msx);
$test->element_exists(
    'ol[aria-label="Public discussions by this contributor"]');
$test->element_exists('a[href="/t/thread-1"]');
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
$duplicate_test->get_ok('/register');
my $duplicate_token = _csrf_token($duplicate_test);
$duplicate_test->post_ok(
    '/register' => form => {
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
my $limited_register_token = _csrf_token($test);
$test->post_ok(
    '/register' => form => {
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
my $limited_login_token = _csrf_token($test);
$test->post_ok(
    '/login' => form => {
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

1;
