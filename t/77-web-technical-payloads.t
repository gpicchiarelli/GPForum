# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Test::FixedClock;
use GPForum::Test::WebPayloadRuntime;
use GPForum::Web::HealthPayload;
use GPForum::Web::RealtimePayload;

our $VERSION = '0.001';

const my $HTTP_OK                  => 200;
const my $HTTP_SERVICE_UNAVAILABLE => 503;

my $clock = GPForum::Test::FixedClock->new( iso8601 => '2026-05-28T12:00:00Z' );

is_deeply(
    GPForum::Web::HealthPayload->live( clock => $clock ),
    {
        status => 'ok',
        check  => 'live',
        time   => '2026-05-28T12:00:00Z',
    },
    'health live payload is stable'
);

is( GPForum::Web::HealthPayload->ready_status_code('ok'),
    $HTTP_OK, 'ready ok maps to HTTP 200' );
is( GPForum::Web::HealthPayload->ready_status_code('degraded'),
    $HTTP_OK, 'ready degraded maps to HTTP 200' );
is( GPForum::Web::HealthPayload->ready_status_code('fail'),
    $HTTP_SERVICE_UNAVAILABLE, 'ready fail maps to HTTP 503' );
is( GPForum::Web::HealthPayload->ready_status_code('unknown'),
    $HTTP_SERVICE_UNAVAILABLE, 'unknown readiness maps to HTTP 503' );

is_deeply(
    GPForum::Web::HealthPayload->ready_anonymous(
        {
            status      => 'degraded',
            check       => 'ready',
            checks      => [ { name => 'replication_slots', error => 'x' } ],
            environment => 'production',
            runtime     => { web_processes => 4 },
        }
    ),
    { status => 'degraded', check => 'ready' },
    'anonymous readiness keeps the status and drops the report'
);
is_deeply(
    GPForum::Web::HealthPayload->summary_anonymous,
    { status => 'ok' },
    'anonymous summary is the status alone'
);

is_deeply(
    GPForum::Web::HealthPayload->summary(
        config  => GPForum::Config->new( environment => 'test' ),
        runtime => GPForum::Test::WebPayloadRuntime->new,
        clock   => $clock,
    ),
    {
        status       => 'ok',
        application  => 'GPForum',
        environment  => 'test',
        runtime      => { web_processes => 4 },
        os           => { kernel        => 'test-kernel' },
        os_features  => { feature       => 'ok' },
        os_sockets   => { sockets       => 'ok' },
        os_processes => { processes     => 'ok' },
        time         => '2026-05-28T12:00:00Z',
    },
    'health summary payload is stable'
);

is_deeply(
    GPForum::Web::RealtimePayload->connected(
        connection_id => 'connection-1',
        fallback      => { poll_after_seconds => 30 },
    ),
    {
        type          => 'realtime.connected',
        connection_id => 'connection-1',
        fallback      => { poll_after_seconds => 30 },
    },
    'realtime connected payload is stable'
);

is_deeply(
    GPForum::Web::RealtimePayload->subscribed( channel => 'thread:thread-1' ),
    {
        type    => 'subscribed',
        channel => 'thread:thread-1',
    },
    'realtime subscribed payload is stable'
);

is_deeply(
    GPForum::Web::RealtimePayload->error( reason => 'wrong_recipient' ),
    {
        type   => 'error',
        reason => 'wrong_recipient',
    },
    'realtime error payload is stable'
);

done_testing();

1;
