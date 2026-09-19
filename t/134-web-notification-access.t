package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Web::NotificationAccess;
use Test::More;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT     => 25;
const my $WRITE_RATE_LIMIT  => 120;
const my $WRITE_RATE_WINDOW => 60;
const my $REQUESTED_LIMIT   => 10;

my $access = GPForum::Web::NotificationAccess->new;

is( $access->page_limit(undef),
    $DEFAULT_LIMIT, 'page_limit defaults a missing size' );
is( $access->page_limit(0), $DEFAULT_LIMIT, 'page_limit defaults a zero size' );
is( $access->page_limit($REQUESTED_LIMIT),
    $REQUESTED_LIMIT, 'page_limit keeps an explicit size' );

is_deeply(
    $access->write_rate_input(
        {
            action   => 'notification.read',
            actor_id => 'user-1',
        }
    ),
    {
        action         => 'notification.read',
        actor_id       => 'user-1',
        limit          => $WRITE_RATE_LIMIT,
        scope          => 'notification_http',
        window_seconds => $WRITE_RATE_WINDOW,
    },
    'write_rate_input uses the notification HTTP window'
);

ok(
    $access->is_failed( { status => 'failed' } ),
    'is_failed accepts a failed workflow'
);
ok(
    !$access->is_failed( { status => 'not_found' } ),
    'is_failed ignores a missing-row status'
);

is( $access->failure_status( { status => 'not_found' } ),
    'not_found', 'failure_status keeps not_found' );
ok( !defined $access->failure_status( { status => 'failed' } ),
    'failure_status ignores system failures' );
ok( !defined $access->failure_status( { status => 'ok' } ),
    'failure_status ignores success' );

done_testing();

1;
