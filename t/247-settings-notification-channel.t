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
use GPForum::Test::DriftedNotificationPreferenceStore;
use GPForum::Test::FixedClock;
use GPForum::Test::IdentitySecurityAudit;
use GPForum::Test::IdentityStore;
use GPForum::Test::NotificationResultSet;
use GPForum::Test::NotificationSchema;

our $VERSION = '0.001';

const my $HTTP_ACCEPTED    => 202;
const my $HTTP_BAD_REQUEST => 400;
const my $HTTP_OK          => 200;

# A channel the preference store does not know was written as in_app: the
# settings form, posting it switched off, turned the member's in-app
# notifications off and answered "saved". It is refused, as a bad request,
# and nothing on the form is written.
my $rows  = GPForum::Test::NotificationResultSet->new;
my $store = GPForum::Test::DriftedNotificationPreferenceStore->new(
    clock  => GPForum::Test::FixedClock->new,
    schema => GPForum::Test::NotificationSchema->new(
        resultsets => { NotificationPreference => $rows },
    ),
);
my $identity_store = GPForum::Test::IdentityStore->new;
my $test           = _signed_in_app( $store, $identity_store );

$test->get_ok('/settings');
$test->status_is($HTTP_OK);
$test->post_ok(
    '/settings' => form => {
        command_id                           => _command_id_in_form($test),
        csrf_token                           => _csrf_token($test),
        locale                               => 'it',
        notification_email_enabled           => 1,
        notification_in_app_digest_frequency => 'immediate',
        notification_in_app_enabled          => 1,
        theme                                => 'high_contrast',
    }
);
$test->status_is( $HTTP_BAD_REQUEST,
    'a form posting an unknown notification channel is a bad request' );

is( scalar @{ $rows->created },
    0, 'no notification preference is written for it' );
ok( $store->channel_enabled( 'user-1', 'in_app' ),
    'in-app notifications stay on' );
is( $identity_store->preferred_locale,
    undef, 'the rest of the form is not saved either' );

done_testing();

sub _signed_in_app {
    my ( $preference_store, $identities ) = @_;

    my $app = Test::Mojo->new('GPForum');
    $app->app->helper( gp_identity_store => sub { return $identities; } );
    $app->app->helper(
        gp_command_idempotency => sub {
            return GPForum::Test::CommandIdempotency->new;
        }
    );
    $app->app->helper(
        gp_identity_security_audit => sub {
            return GPForum::Test::IdentitySecurityAudit->new;
        }
    );
    $app->app->helper(
        gp_notification_preference_store => sub {
            return $preference_store;
        }
    );

    $app->get_ok('/login');
    $app->post_ok(
        '/login' => form => {
            command_id => _command_id($app),
            csrf_token => _csrf_token($app),
            identifier => 'giacomo_forum',
            password   => 'correct horse battery staple',
        }
    );
    $app->status_is($HTTP_ACCEPTED);

    return $app;
}

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

# The settings page has several forms, each with its own command id.
sub _command_id_in_form {
    my ($test_object) = @_;

    my $body  = $test_object->tx->res->body;
    my $start = index $body, q{action="/settings"};
    if ( $start < 0 ) {
        return;
    }

    my ($command_id) =
      substr( $body, $start ) =~ /name="command_id" [^>]+ value="([^"]+)"/msx;

    return $command_id;
}

1;
