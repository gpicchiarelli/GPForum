package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';

use GPForum::Web::HealthPayload;
use GPForum::Web::RealtimePayload;

our $VERSION = '0.001';

my $clock = GPForum::Test::WebPayloadClock->new;

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
    200, 'ready ok maps to HTTP 200' );
is( GPForum::Web::HealthPayload->ready_status_code('degraded'),
    200, 'ready degraded maps to HTTP 200' );
is( GPForum::Web::HealthPayload->ready_status_code('fail'),
    503, 'ready fail maps to HTTP 503' );
is( GPForum::Web::HealthPayload->ready_status_code('unknown'),
    503, 'unknown readiness maps to HTTP 503' );

is_deeply(
    GPForum::Web::HealthPayload->summary(
        config  => GPForum::Test::WebPayloadConfig->new,
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

package GPForum::Test::WebPayloadClock;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub now_iso8601 {
    return '2026-05-28T12:00:00Z';
}

package GPForum::Test::WebPayloadConfig;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub environment {
    return 'test';
}

package GPForum::Test::WebPayloadRuntime;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub as_hash {
    return { web_processes => 4 };
}

sub os_profile {
    return GPForum::Test::WebPayloadProfile->new;
}

sub os_feature_settings {
    return { enabled => 1 };
}

package GPForum::Test::WebPayloadProfile;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub snapshot {
    return { kernel => 'test-kernel' };
}

sub feature_snapshot {
    return { feature => 'ok' };
}

sub socket_snapshot {
    return { sockets => 'ok' };
}

sub process_snapshot {
    return { processes => 'ok' };
}

1;
