package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Bootstrap::Routes;
use GPForum::Controller::Identity;
use GPForum::Controller::Identity::Base;
use GPForum::Controller::Identity::Email;
use GPForum::Controller::Identity::Password;
use GPForum::Controller::Identity::Verification;
use GPForum::Controller::Identity::Profile;
use GPForum::Controller::Identity::Settings;
use Mojolicious;
use Test::More;

our $VERSION = '0.001';

ok( GPForum::Controller::Identity->can('login'),
    'session controller keeps login' );
ok(
    !$GPForum::Controller::Identity::{settings},
    'session controller no longer owns settings'
);
ok( $GPForum::Controller::Identity::Password::{reset_password},
    'password controller owns reset completion' );
ok( $GPForum::Controller::Identity::Email::{confirm_email_change},
    'email controller owns confirmation' );
ok(
    $GPForum::Controller::Identity::Verification::{verify_email},
    'verification controller owns registration verification'
);
ok(
    $GPForum::Controller::Identity::Settings::{settings},
    'settings controller owns the settings page'
);
ok(
    $GPForum::Controller::Identity::Profile::{profile},
    'profile controller owns public profiles'
);
isa_ok(
    'GPForum::Controller::Identity::Password',
    'GPForum::Controller::Identity::Base'
);
isa_ok(
    'GPForum::Controller::Identity::Email',
    'GPForum::Controller::Identity::Base'
);
isa_ok(
    'GPForum::Controller::Identity::Settings',
    'GPForum::Controller::Identity::Base'
);
isa_ok(
    'GPForum::Controller::Identity::Profile',
    'GPForum::Controller::Identity::Base'
);

my $app = Mojolicious->new;
GPForum::Bootstrap::Routes->register( application => $app );
_assert_route( $app, 'login',        'Identity', 'login_form' );
_assert_route( $app, 'login_submit', 'Identity', 'login' );
_assert_route( $app, 'logout',       'Identity', 'logout' );
_assert_route( $app, 'password_reset_complete',
    'Identity::Password', 'reset_password' );
_assert_route( $app, 'settings_password_update',
    'Identity::Password', 'change_password' );
_assert_route(
    $app,              'settings_email_update',
    'Identity::Email', 'request_email_change'
);
_assert_route( $app, 'settings',     'Identity::Settings',     'settings' );
_assert_route( $app, 'profile',      'Identity::Profile',      'profile' );
_assert_route( $app, 'email_verify', 'Identity::Verification', 'verify_email' );
_assert_route( $app, 'email_verify_request',
    'Identity::Verification', 'email_verify_request_form' );

done_testing();

sub _assert_route {
    my ( $application, $name, $controller, $action ) = @_;

    my $to = $application->routes->find($name)->to;
    is( $to->{controller}, $controller, "$name uses $controller" );
    is( $to->{action},     $action,     "$name uses $action" );

    return;
}

1;
