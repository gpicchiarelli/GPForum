# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Test::AllowLimiter;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::FailingIdentitySecurityAudit;
use GPForum::Test::IdentityStore;
use GPForum::Test::NotificationPreferenceStore;

our $VERSION = '0.001';

const my $HTTP_FOUND        => 302;
const my $HTTP_OK           => 200;
const my $HTTP_SERVER_ERROR => 500;
const my $JSON              => { Accept => 'application/json' };
const my $AUDIT_WARNING =>
  'warn: identity audit degraded: security audit is down';

# The two identity reads that sit in a try: the settings page's notification
# preferences, whose failure answers 500 instead of Mojolicious's exception
# page, and the login audit, whose failure is logged and leaves the sign-in
# standing.

my $preferences = GPForum::Test::NotificationPreferenceStore->new;
my $test        = Test::Mojo->new('GPForum');
my $app         = $test->app;
my @logged      = _capture_log($app);
_install_fakes($app);

subtest 'a login whose audit dies still signs the member in' => sub {
    $test->get_ok('/login')->status_is($HTTP_OK);
    my $body         = $test->tx->res->body;
    my ($csrf_token) = $body =~ /name="csrf_token" [^>]+ value="([^"]+)"/msx;
    my ($command_id) = $body =~ /name="command_id" [^>]+ value="([^"]+)"/msx;
    $test->post_ok(
        '/login' => form => {
            command_id => $command_id,
            csrf_token => $csrf_token,
            identifier => 'giacomo_forum',
            password   => 'correct horse battery staple',
        }
    )->status_is($HTTP_FOUND);
    ok(
        ( grep { index( $_, $AUDIT_WARNING ) == 0 } @logged ),
        'the audit failure is logged as a warning'
    ) or diag explain \@logged;
    $test->get_ok('/settings')->status_is( $HTTP_OK, 'the session stands' );
};

subtest 'a settings page whose preferences cannot be read answers 500' => sub {
    $preferences->fail(1);
    $test->get_ok( '/settings' => $JSON )->status_is($HTTP_SERVER_ERROR);
    $test->json_is(
        q{} => {
            error  => 'internal error',
            status => 'error',
            title  => 'Internal error',
        },
        'the error payload, not the exception page'
    );
    $preferences->fail(0);
    $test->get_ok('/settings')->status_is( $HTTP_OK, 'and recovers' );
};

done_testing();

sub _capture_log ($application) {
    my $log = $application->log;
    $log->level('trace');
    $log->unsubscribe('message');
    $log->on(
        message => sub ( $, $level, @lines ) {
            push @logged, join q{ }, "$level:", @lines;
        }
    );

    return ();
}

sub _install_fakes ($application) {
    my %fakes = (
        gp_command_idempotency     => GPForum::Test::CommandIdempotency->new,
        gp_identity_security_audit =>
          GPForum::Test::FailingIdentitySecurityAudit->new,
        gp_identity_store                => GPForum::Test::IdentityStore->new,
        gp_notification_preference_store => $preferences,
        gp_rate_limiter                  => GPForum::Test::AllowLimiter->new,
    );
    for my $helper ( sort keys %fakes ) {
        my $fake = $fakes{$helper};
        $application->helper( $helper => sub { return $fake; } );
    }

    return;
}

1;
