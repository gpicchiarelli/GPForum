# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;
use Test::Mojo;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Test::ReadyHealth;

our $VERSION = '0.001';

const my $EXPECTED_TESTS             => 14;
const my $HTTP_OK                    => 200;
const my $DEFAULT_WORKER_PROCESSES   => 2;
const my $DEFAULT_REALTIME_PROCESSES => 1;

plan tests => $EXPECTED_TESTS;

my $test = Test::Mojo->new('GPForum');
$test->app->helper(
    gp_readiness => sub {
        return GPForum::Test::ReadyHealth->new;
    }
);

$test->get_ok('/health');
$test->status_is($HTTP_OK);
$test->json_is( '/status'      => 'ok' );
$test->json_is( '/application' => 'GPForum' );

# GPFORUM_WEB_PROCESSES defaults to auto: as many as this host's CPUs carry.
$test->json_is(
    '/runtime/web_processes' => GPForum::Config->new->automatic_web_processes );

$test->get_ok('/health/live');
$test->status_is($HTTP_OK);
$test->json_is( '/check'  => 'live' );
$test->json_is( '/status' => 'ok' );

$test->get_ok('/health/ready');
$test->status_is($HTTP_OK);
$test->json_is( '/check'                      => 'ready' );
$test->json_is( '/runtime/worker_processes'   => $DEFAULT_WORKER_PROCESSES );
$test->json_is( '/runtime/realtime_processes' => $DEFAULT_REALTIME_PROCESSES );

1;
