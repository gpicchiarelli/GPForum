package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Test::RealtimeRequest;
use GPForum::Web::RealtimeAccess;
use Test::More;

our $VERSION = '0.001';

const my $OVERSIZE_BYTES    => 2_100;
const my $CONNECT_LIMIT     => 30;
const my $SUBSCRIBE_LIMIT   => 120;
const my $WINDOW_SECONDS    => 60;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_TOO_MANY     => 429;

my $access = GPForum::Web::RealtimeAccess->new;
my $same =
  GPForum::Test::RealtimeRequest->new( origin => 'https://forum.example.test',
  );

ok( $access->origin_allowed($same),
    'origin_allowed accepts a missing-or-matching request origin' );
is( $access->request_origin($same),
    'https://forum.example.test', 'request_origin uses scheme and Host' );
is(
    $access->configured_origin('https://forum.example.test:8443'),
    'https://forum.example.test:8443',
    'configured_origin preserves a non-default port'
);

my $missing = GPForum::Test::RealtimeRequest->new;
ok( $access->origin_allowed($missing),
    'origin_allowed allows a handshake without Origin' );

my $foreign =
  GPForum::Test::RealtimeRequest->new( origin => 'https://other.example.test',
  );
ok(
    !$access->origin_allowed($foreign),
    'origin_allowed rejects a foreign Origin'
);

ok( $access->is_subscribe( { type => 'subscribe', channel => 'thread:1' } ),
    'is_subscribe accepts a subscribe message' );
ok(
    !$access->is_subscribe( { type => 'ping' } ),
    'is_subscribe rejects a non-subscribe message'
);
ok( !$access->is_subscribe(undef), 'is_subscribe rejects an empty payload' );

is( $access->channel_type('notifications:user-1'),
    'notifications', 'channel_type reads the type prefix' );
is( $access->channel_type('broken'),
    'unknown', 'channel_type maps a malformed channel to unknown' );
is( $access->channel_type(undef),
    'unknown', 'channel_type maps an undefined channel to unknown' );

ok(
    !$access->payload_too_large( { type => 'subscribe' } ),
    'payload_too_large accepts a small subscribe command'
);
ok( $access->payload_too_large( { body => 'x' x $OVERSIZE_BYTES } ),
    'payload_too_large rejects an oversized payload' );

is( $access->connect_action, 'realtime.connect',
    'connect_action keeps the handshake action' );
is( $access->subscribe_action,
    'realtime.subscribe', 'subscribe_action keeps the subscribe action' );

is_deeply(
    $access->write_rate_input(
        {
            action   => 'realtime.connect',
            actor_id => 'user-1',
        }
    ),
    {
        action         => 'realtime.connect',
        actor_id       => 'user-1',
        limit          => $CONNECT_LIMIT,
        scope          => 'user',
        window_seconds => $WINDOW_SECONDS,
    },
    'write_rate_input uses the connect window'
);

is( $access->write_limit_for('realtime.subscribe'),
    $SUBSCRIBE_LIMIT, 'write_limit_for caps subscribe' );
is( $access->write_limit_for('realtime.connect'),
    $CONNECT_LIMIT, 'write_limit_for keeps the connect cap' );
is( $access->write_limit_for('realtime.unknown'),
    $CONNECT_LIMIT, 'write_limit_for defaults unknown actions to connect' );

is_deeply(
    $access->origin_denied,
    {
        status => $HTTP_FORBIDDEN,
        text   => 'Origin denied',
    },
    'origin_denied keeps the handshake text'
);
is_deeply(
    $access->authentication_required,
    {
        status => $HTTP_UNAUTHORIZED,
        text   => 'Authentication required',
    },
    'authentication_required keeps the handshake text'
);
is_deeply(
    $access->too_many_connections,
    {
        status => $HTTP_TOO_MANY,
        text   => 'Too many realtime connections',
    },
    'too_many_connections keeps the connect-limit text'
);

done_testing();

1;
