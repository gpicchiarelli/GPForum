package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Notification::Workflow;
use GPForum::Test::NotificationWorkflowServices;
use Test::More;

our $VERSION = '0.001';

my $services = GPForum::Test::NotificationWorkflowServices->new;
my $workflow = GPForum::Service::Notification::Workflow->new(
    dispatcher       => $services,
    preference_store => $services,
);

my $read = $workflow->mark_read(
    {
        notification_id => 'note-1',
        user_id         => 'user-1',
    }
);
ok( $read->{ok}, 'mark_read succeeds for a known inbox row' );
is( $read->{stored}{notification_id},
    'note-1', 'mark_read returns the dispatcher result' );
is( $read->{stored}{recipient_user_id},
    'user-1', 'mark_read keeps the recipient identity' );

my $missing = $workflow->mark_read(
    {
        notification_id => 'missing',
        user_id         => 'user-1',
    }
);
is( $missing->{status},
    'not_found', 'mark_read maps a missing inbox row to not_found' );
is( $missing->{error}, 'not_found',
    'mark_read keeps the dispatcher missing error' );

my $empty = $workflow->mark_read(
    {
        notification_id => 'gone',
        user_id         => 'user-1',
    }
);
is( $empty->{status},
    'not_found', 'mark_read maps an empty dispatcher result to not_found' );

my $failed = $workflow->mark_read(
    {
        notification_id => 'boom',
        user_id         => 'user-1',
    }
);
is( $failed->{status},
    'failed', 'mark_read maps dispatcher exceptions to failed' );

my $saved = $workflow->set_preferences(
    {
        preferences => [ { channel => 'in_app', enabled => 1 } ],
        user_id     => 'user-1',
    }
);
ok( $saved->{ok}, 'set_preferences succeeds for a known user' );
is( $saved->{stored}[0]{channel},
    'in_app', 'set_preferences returns the stored channel row' );
is( $services->preference_updates->[0]{user_id},
    'user-1', 'set_preferences scopes the write to the member' );

my $empty_prefs = $workflow->set_preferences(
    {
        preferences => [ { channel => 'email', enabled => 0 } ],
        user_id     => 'gone',
    }
);
is( $empty_prefs->{status},
    'not_found', 'set_preferences maps an empty store result to not_found' );

my $failed_prefs = $workflow->set_preferences(
    {
        preferences => [ { channel => 'email', enabled => 0 } ],
        user_id     => 'boom',
    }
);
is( $failed_prefs->{status},
    'failed', 'set_preferences maps store exceptions to failed' );

done_testing();

1;
