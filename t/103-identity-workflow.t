package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Identity::Workflow;
use GPForum::Test::IdentityMailer;
use GPForum::Test::IdentityStore;
use Test::More;

our $VERSION = '0.001';

my $mailer   = GPForum::Test::IdentityMailer->new;
my $services = GPForum::Test::IdentityStore->new;
my $workflow = GPForum::Service::Identity::Workflow->new(
    mailer       => $mailer,
    registration => $services,
    store        => $services,
);

my $registered = $workflow->register( { username => 'giacomo' } );
ok( $registered->{ok}, 'register succeeds for a valid username' );
is( $registered->{stored}{registration}{user}{username},
    'giacomo', 'register returns the prepared registration' );

my $missing_username = $workflow->register( { username => q{} } );
is( $missing_username->{status},
    'invalid', 'register rejects an empty username' );
is(
    $missing_username->{errors}{username},
    'username is required',
    'register names the missing username'
);

$services->duplicate(1);
my $duplicate = $workflow->register( { username => 'giacomo' } );
is( $duplicate->{status}, 'invalid',
    'register hides duplicate account errors' );
is(
    $duplicate->{errors}{registration},
    'registration request could not be accepted',
    'register does not enumerate existing accounts'
);
$services->duplicate(0);

my $logged_in = $workflow->login(
    {
        identifier => 'giacomo',
        password   => 'secret-password',
    }
);
ok( $logged_in->{ok}, 'login succeeds for known credentials' );
is( $logged_in->{stored}{user_id}, 'user-1', 'login returns the stored user' );

my $missing_password = $workflow->login(
    {
        identifier => 'giacomo',
        password   => q{},
    }
);
is( $missing_password->{status}, 'invalid', 'login rejects an empty password' );

$services->invalid_login(1);
my $rejected = $workflow->login(
    {
        identifier => 'giacomo',
        password   => 'secret-password',
    }
);
is( $rejected->{status},
    'rejected', 'login maps invalid credentials to rejected' );
$services->invalid_login(0);

$services->unverified_login(1);
my $unverified = $workflow->login(
    {
        identifier => 'giacomo',
        password   => 'secret-password',
    }
);
is( $unverified->{status},
    'rejected', 'login maps pending accounts to rejected' );
is( $unverified->{error},
    'unverified', 'login names unverified pending accounts' );
$services->unverified_login(0);

my $logged_out = $workflow->logout(
    {
        session_id => 'session-1',
        user_id    => 'user-1',
    }
);
ok( $logged_out->{ok}, 'logout revokes a known session' );

my $skipped = $workflow->logout( { session_id => q{}, user_id => 'user-1' } );
ok( $skipped->{ok}, 'logout succeeds when no session id is present' );
ok( $skipped->{stored}{skipped}, 'logout skips revocation without a session' );

my $reset_requested =
  $workflow->request_password_reset( { identifier => 'giacomo@example.test' } );
ok( $reset_requested->{ok},
    'request_password_reset succeeds for an identifier' );
ok(
    !defined $reset_requested->{stored}{token}{raw_token},
    'request_password_reset hides the raw token from callers'
);
is( $mailer->sent->[-1]{kind},
    'password_reset', 'request_password_reset sends reset mail' );

my $missing_identifier =
  $workflow->request_password_reset( { identifier => q{} } );
is( $missing_identifier->{status},
    'invalid', 'request_password_reset rejects an empty identifier' );

my $reset = $workflow->reset_password(
    {
        password => 'new-secret-password',
        token    => 'reset-token',
    }
);
ok( $reset->{ok}, 'reset_password succeeds for a complete command' );

my $changed = $workflow->change_password(
    {
        current_password => 'old-secret',
        new_password     => 'new-secret-password',
        user_id          => 'user-1',
    }
);
ok( $changed->{ok}, 'change_password succeeds for a known user' );

my $email = $workflow->request_email_change(
    {
        email   => 'new@example.test',
        user_id => 'user-1',
    }
);
ok( $email->{ok}, 'request_email_change succeeds for a known user' );

my $confirmed = $workflow->confirm_email_change( { token => 'email-token' } );
ok( $confirmed->{ok}, 'confirm_email_change succeeds for a known token' );

my $verify_requested =
  $workflow->request_email_verification( { identifier => 'giacomo' } );
ok( $verify_requested->{ok},
    'request_email_verification succeeds for an identifier' );

my $verified = $workflow->verify_email( { token => 'verify-token' } );
ok( $verified->{ok}, 'verify_email succeeds for a known token' );

my $missing_verify = $workflow->verify_email( { token => q{} } );
is( $missing_verify->{status},
    'invalid', 'verify_email rejects an empty token' );

my $locale = $workflow->update_preferred_locale(
    {
        preferred_locale => 'it',
        user_id          => 'user-1',
    }
);
ok( $locale->{ok}, 'update_preferred_locale succeeds for a known user' );
is( $locale->{stored}{preferred_locale},
    'it', 'update_preferred_locale stores the requested locale' );

my $missing_locale = $workflow->update_preferred_locale(
    {
        preferred_locale => q{},
        user_id          => 'user-1',
    }
);
is( $missing_locale->{status},
    'invalid', 'update_preferred_locale rejects an empty locale' );

my $theme = $workflow->update_preferred_theme(
    {
        preferred_theme => 'high_contrast',
        user_id         => 'user-1',
    }
);
ok( $theme->{ok}, 'update_preferred_theme succeeds for a known user' );
is( $theme->{stored}{preferred_theme},
    'high_contrast', 'update_preferred_theme stores the requested theme' );

my $missing_theme = $workflow->update_preferred_theme(
    {
        preferred_theme => q{},
        user_id         => 'user-1',
    }
);
is( $missing_theme->{status},
    'invalid', 'update_preferred_theme rejects an empty theme' );

done_testing();

1;
