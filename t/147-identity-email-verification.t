package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Service::Identity::Workflow;
use GPForum::Test::AllowLimiter;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::IdentityStore;
use Test::More;
use Test::Mojo;

our $VERSION = '0.001';

const my $HTTP_OK        => 200;
const my $HTTP_ACCEPTED  => 202;
const my $HTTP_FORBIDDEN => 403;

my $services = GPForum::Test::IdentityStore->new;
my $workflow = GPForum::Service::Identity::Workflow->new(
    registration => $services,
    store        => $services,
);

my $reset = $workflow->request_password_reset(
    {
        command_id => 'reset-cmd-1',
        identifier => 'giacomo@example.test',
    }
);
ok( $reset->{ok}, 'workflow still accepts a password reset' );
ok(
    !defined $reset->{stored}{token}{raw_token},
    'workflow strips the raw reset token from the result'
);
is( $services->lifecycle_calls->[-1]{method},
    'request_password_reset', 'password reset stays on the store boundary' );

my $email = $workflow->request_email_change(
    {
        command_id => 'email-cmd-1',
        email      => 'new@example.test',
        user_id    => 'user-1',
    }
);
ok( $email->{ok}, 'workflow still accepts an email change' );
ok( !defined $email->{stored}{token}{raw_token},
    'workflow strips the raw email-change token from the result' );
is( $services->lifecycle_calls->[-1]{method},
    'request_email_change', 'email change stays on the store boundary' );

my $registered = $workflow->register(
    {
        command_id   => 'register-cmd-1',
        display_name => 'Giacomo Picchiarelli',
        email        => 'giacomo@example.test',
        password     => 'correct horse battery staple',
        username     => 'giacomo',
    }
);
ok( $registered->{ok}, 'register still persists a pending account' );
is( $services->lifecycle_calls->[-1]{method},
    'request_email_verification',
    'register asks the store to issue verification' );

my $verified = $workflow->verify_email(
    {
        command_id => 'verify-complete-1',
        token      => 'verify-token',
    }
);
ok( $verified->{ok}, 'verify_email completes a known token' );

my $resent = $workflow->request_email_verification(
    {
        command_id => 'verify-cmd-1',
        identifier => 'giacomo',
    }
);
ok( $resent->{ok}, 'request_email_verification accepts an identifier' );
is( $services->lifecycle_calls->[-1]{method},
    'request_email_verification', 'resend stays on the store boundary' );

my $test = Test::Mojo->new('GPForum');
$test->app->helper( gp_identity_store => sub { return $services; } );
$test->app->helper(
    gp_command_idempotency => sub {
        return GPForum::Test::CommandIdempotency->new;
    }
);
$test->app->helper(
    gp_rate_limiter => sub { return GPForum::Test::AllowLimiter->new; } );

$test->get_ok('/email/verify');
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Resend verification email' );
$test->element_exists('input[name="csrf_token"]');
$test->element_exists('input[name="command_id"]');

$test->post_ok('/email/verify/request');
$test->status_is($HTTP_FORBIDDEN);

$test->get_ok('/email/verify');
my $resend_token      = _csrf_token($test);
my $resend_command_id = _command_id($test);
$test->post_ok(
    '/email/verify/request' => form => {
        command_id => $resend_command_id,
        csrf_token => $resend_token,
        identifier => 'giacomo@example.test',
    }
);
$test->status_is($HTTP_ACCEPTED);
$test->text_is( 'h1' => 'Verification email requested' );

$test->get_ok('/email/verify/verify-token');
$test->status_is($HTTP_OK);
$test->element_exists('input[name="token"][value="verify-token"]');
$test->element_exists('input[name="command_id"]');

$test->post_ok('/email/verify/complete');
$test->status_is($HTTP_FORBIDDEN);

$test->get_ok('/email/verify/verify-token');
my $complete_token      = _csrf_token($test);
my $complete_command_id = _command_id($test);
$test->post_ok(
    '/email/verify/complete' => form => {
        command_id => $complete_command_id,
        csrf_token => $complete_token,
        token      => 'verify-token',
    }
);
$test->status_is($HTTP_ACCEPTED);
$test->text_is( 'h1' => 'Email verified' );
is( $services->lifecycle_calls->[-1]{method},
    'confirm_email_verification',
    'verification completion reaches identity store' );

done_testing();

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

1;
