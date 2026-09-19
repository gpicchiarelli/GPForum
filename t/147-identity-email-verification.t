package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Service::Identity::Workflow;
use GPForum::Test::AllowLimiter;
use GPForum::Test::IdentityMailer;
use GPForum::Test::IdentityStore;
use Test::More;
use Test::Mojo;

our $VERSION = '0.001';

const my $HTTP_OK        => 200;
const my $HTTP_ACCEPTED  => 202;
const my $HTTP_FORBIDDEN => 403;

my $mailer   = GPForum::Test::IdentityMailer->new;
my $services = GPForum::Test::IdentityStore->new;
my $workflow = GPForum::Service::Identity::Workflow->new(
    mailer       => $mailer,
    registration => $services,
    store        => $services,
);

my $reset =
  $workflow->request_password_reset( { identifier => 'giacomo@example.test' } );
ok( $reset->{ok}, 'workflow still accepts a password reset' );
ok(
    !defined $reset->{stored}{token}{raw_token},
    'workflow strips the raw reset token from the result'
);
is( $mailer->sent->[0]{kind},
    'password_reset', 'workflow sends password-reset mail' );
is( $mailer->sent->[0]{token},
    'reset-token', 'workflow gives the mailer the raw reset token' );
is( $mailer->sent->[0]{to},
    'giacomo@example.test', 'workflow addresses reset mail to the member' );

my $email = $workflow->request_email_change(
    {
        email   => 'new@example.test',
        user_id => 'user-1',
    }
);
ok( $email->{ok}, 'workflow still accepts an email change' );
ok( !defined $email->{stored}{token}{raw_token},
    'workflow strips the raw email-change token from the result' );
is( $mailer->sent->[1]{kind},
    'email_change', 'workflow sends email-change mail' );

my $registered = $workflow->register(
    {
        display_name => 'Giacomo Picchiarelli',
        email        => 'giacomo@example.test',
        password     => 'correct horse battery staple',
        username     => 'giacomo',
    }
);
ok( $registered->{ok}, 'register still persists a pending account' );
is( $mailer->sent->[2]{kind},
    'email_verification', 'register sends verification mail' );
is( $mailer->sent->[2]{token},
    'verify-token', 'register gives the mailer the raw verification token' );

my $verified = $workflow->verify_email( { token => 'verify-token' } );
ok( $verified->{ok}, 'verify_email completes a known token' );

my $resent =
  $workflow->request_email_verification( { identifier => 'giacomo' } );
ok( $resent->{ok}, 'request_email_verification accepts an identifier' );
is( $mailer->sent->[-1]{kind},
    'email_verification', 'resend sends verification mail' );

my $test = Test::Mojo->new('GPForum');
$test->app->helper( gp_identity_store => sub { return $services; } );
$test->app->helper(
    gp_rate_limiter => sub { return GPForum::Test::AllowLimiter->new; } );

$test->get_ok('/email/verify');
$test->status_is($HTTP_OK);
$test->text_is( 'h1' => 'Resend verification email' );
$test->element_exists('input[name="csrf_token"]');

$test->post_ok('/email/verify/request');
$test->status_is($HTTP_FORBIDDEN);

$test->get_ok('/email/verify');
my $resend_token = _csrf_token($test);
$test->post_ok(
    '/email/verify/request' => form => {
        csrf_token => $resend_token,
        identifier => 'giacomo@example.test',
    }
);
$test->status_is($HTTP_ACCEPTED);
$test->text_is( 'h1' => 'Verification email requested' );

$test->get_ok('/email/verify/verify-token');
$test->status_is($HTTP_OK);
$test->element_exists('input[name="token"][value="verify-token"]');

$test->post_ok('/email/verify/complete');
$test->status_is($HTTP_FORBIDDEN);

$test->get_ok('/email/verify/verify-token');
my $complete_token = _csrf_token($test);
$test->post_ok(
    '/email/verify/complete' => form => {
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

1;
