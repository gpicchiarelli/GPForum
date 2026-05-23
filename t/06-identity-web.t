package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;
use Test::Mojo;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::IdentityStore;

our $VERSION = '0.001';

const my $EXPECTED_TESTS   => 41;
const my $HTTP_OK          => 200;
const my $HTTP_ACCEPTED    => 202;
const my $HTTP_BAD_REQUEST => 400;
const my $HTTP_FORBIDDEN   => 403;

plan tests => $EXPECTED_TESTS;

my $test = Test::Mojo->new('GPForum');
$test->app->helper(
    gp_identity_store => sub {
        return GPForum::Test::IdentityStore->new;
    }
);

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

$test->post_ok('/logout');
$test->status_is($HTTP_FORBIDDEN);

$test->get_ok('/login');
my $logout_token = _csrf_token($test);

$test->post_ok( '/logout' => form => { csrf_token => $logout_token } );
$test->status_is($HTTP_ACCEPTED);
$test->text_is( 'h1' => 'Logout request accepted' );

$test->get_ok('/u/giacomo_forum');
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'giacomo_forum' );

sub _csrf_token {
    my ($test_object) = @_;

    my $body = $test_object->tx->res->body;
    my ($token) = $body =~ /name="csrf_token" [^>]+ value="([^"]+)"/msx;

    return $token;
}

1;
