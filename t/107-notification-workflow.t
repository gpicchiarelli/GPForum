package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Notification::Workflow;
use GPForum::Test::CommandIdempotency;
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

my $all_read = $workflow->mark_all_read( { user_id => 'user-1' } );
ok( $all_read->{ok}, 'mark_all_read succeeds for a known inbox' );
is( $all_read->{stored}{marked_count},
    2, 'mark_all_read returns the dispatcher marked count' );
is( $all_read->{stored}{unread_count},
    0, 'mark_all_read returns a cleared unread count' );

my $failed_all = $workflow->mark_all_read( { user_id => 'boom' } );
is( $failed_all->{status},
    'failed', 'mark_all_read maps dispatcher exceptions to failed' );

my $missing_command = $workflow->set_preferences(
    {
        preferences => [ { channel => 'in_app', enabled => 1 } ],
        user_id     => 'user-1',
    }
);
is( $missing_command->{status},
    'invalid', 'set_preferences rejects a missing command_id' );
is(
    $missing_command->{errors}{command_id},
    'command_id is required',
    'set_preferences names the missing command_id'
);

my $saved = $workflow->set_preferences(
    {
        command_id  => 'prefs-1',
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
        command_id  => 'prefs-empty-1',
        preferences => [ { channel => 'email', enabled => 0 } ],
        user_id     => 'gone',
    }
);
is( $empty_prefs->{status},
    'not_found', 'set_preferences maps an empty store result to not_found' );

my $failed_prefs = $workflow->set_preferences(
    {
        command_id  => 'prefs-failed-1',
        preferences => [ { channel => 'email', enabled => 0 } ],
        user_id     => 'boom',
    }
);
is( $failed_prefs->{status},
    'failed', 'set_preferences maps store exceptions to failed' );

my $idempotency = GPForum::Test::CommandIdempotency->new;
my $commanded   = GPForum::Service::Notification::Workflow->new(
    command_idempotency => $idempotency,
    dispatcher          => $services,
    preference_store    => $services,
);
_replay_preferences(
    {
        commanded   => $commanded,
        idempotency => $idempotency,
        input       => {
            command_id  => 'prefs-replay-1',
            preferences => [
                {
                    channel          => 'in_app',
                    digest_frequency => 'immediate',
                    enabled          => 1,
                }
            ],
            user_id => 'user-1',
        },
        request => {
            preferences => [
                {
                    channel          => 'in_app',
                    digest_frequency => 'immediate',
                    enabled          => 1,
                }
            ],
            user_id => 'user-1',
        },
        services => $services,
    }
);

done_testing();

sub _preference_writes {
    my ($store) = @_;

    return scalar @{ $store->preference_updates };
}

sub _replay_preferences {
    my ($job) = @_;

    my $write_issued = $job->{commanded}->set_preferences( $job->{input} );
    ok( $write_issued->{ok}, 'set_preferences records a command' );
    is(
        $job->{idempotency}->last_input->{command_type},
        'notification.preferences',
        'set_preferences uses notification.preferences'
    );
    is_deeply( $job->{idempotency}->last_input->{request},
        $job->{request},
        'set_preferences command log stores channels and user_id' );
    my $write_count    = _preference_writes( $job->{services} );
    my $write_replayed = GPForum::Service::Notification::Workflow->new(
        command_idempotency => GPForum::Test::CommandIdempotency->new(
            replay_response => $write_issued,
        ),
        dispatcher       => $job->{services},
        preference_store => $job->{services},
    )->set_preferences( $job->{input} );
    is_deeply( $write_replayed, $write_issued,
        'set_preferences replays the recorded result' );
    is( _preference_writes( $job->{services} ),
        $write_count, 'set_preferences replay does not persist twice' );
    my $write_conflict = GPForum::Service::Notification::Workflow->new(
        command_idempotency => GPForum::Test::CommandIdempotency->new(
            conflict => 1,
        ),
        dispatcher       => $job->{services},
        preference_store => $job->{services},
    )->set_preferences( $job->{input} );
    is( $write_conflict->{status},
        'conflict',
        'set_preferences rejects a reused command_id for another request' );

    return;
}

1;
