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
use GPForum::Test::IdentitySecurityAudit;
use GPForum::Test::IdentityStore;
use GPForum::Test::RecordingLimiter;

our $VERSION = '0.001';

const my $ACCOUNT_LIMIT  => 20;
const my $HTTP_TOO_MANY  => 429;
const my $WINDOW_SECONDS => 300;

# A login is limited per address and per account. Per address alone, many
# addresses each under their limit could try one account thousands of times.
my $limiter = GPForum::Test::RecordingLimiter->new;
my $client  = _client($limiter);

_login( $client, '  Giacomo@Example.test ' );
is_deeply(
    [ map { $_->{action} } @{ $limiter->checks } ],
    [qw(identity.login identity.login_account)],
    'a login is checked per address, then per account'
);
is(
    $limiter->checks->[1]{actor_id},
    'account:giacomo@example.test',
    'the account as it signs in'
);
is( $limiter->checks->[1]{limit}, $ACCOUNT_LIMIT, 'twenty tries per account' );
is( $limiter->checks->[1]{window_seconds},
    $WINDOW_SECONDS, 'every five minutes, from every address together' );

my $locked = GPForum::Test::RecordingLimiter->new(
    denied => { 'identity.login_account' => 1 } );
my $locked_client = _client($locked);
_login( $locked_client, 'giacomo@example.test' );
$locked_client->status_is( $HTTP_TOO_MANY,
    'an account past its limit is refused whatever the address' );

done_testing();

sub _client {
    my ($rate_limiter) = @_;

    my $test = Test::Mojo->new('GPForum');
    $test->app->helper(
        gp_identity_store => sub {
            return GPForum::Test::IdentityStore->new( invalid_login => 1 );
        }
    );
    $test->app->helper( gp_identity_security_audit =>
          sub { return GPForum::Test::IdentitySecurityAudit->new; } );
    $test->app->helper( gp_command_idempotency =>
          sub { return GPForum::Test::CommandIdempotency->new; } );
    $test->app->helper( gp_rate_limiter => sub { return $rate_limiter; } );

    return $test;
}

sub _login {
    my ( $test, $identifier ) = @_;

    $test->get_ok('/login');
    my $body         = $test->tx->res->body;
    my ($token)      = $body =~ /name="csrf_token" [^>]+ value="([^"]+)"/msx;
    my ($command_id) = $body =~ /name="command_id" [^>]+ value="([^"]+)"/msx;
    $test->post_ok(
        '/login' => form => {
            command_id => $command_id,
            csrf_token => $token,
            identifier => $identifier,
            password   => 'wrong password value',
        }
    );

    return;
}

1;
