# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Community::Workflow;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::CommunityWorkflowServices;
use Test::More;

our $VERSION = '0.001';

my $services = GPForum::Test::CommunityWorkflowServices->new;
my $workflow = GPForum::Service::Community::Workflow->new(
    bookmark_store     => $services,
    report_store       => $services,
    subscription_store => $services,
);

my $missing = $workflow->save_bookmark(
    {
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'user-1',
    }
);
is( $missing->{status}, 'invalid',
    'save_bookmark rejects a missing command_id' );
is(
    $missing->{errors}{command_id},
    'command_id is required',
    'save_bookmark names the missing command_id'
);

my $saved = $workflow->save_bookmark(
    {
        command_id  => 'bookmark-1',
        note        => 'later',
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'user-1',
    }
);
ok( $saved->{ok}, 'save_bookmark succeeds for a known member' );
is( $saved->{stored}{target_id},
    'thread-1', 'save_bookmark returns the stored target' );
is( $services->bookmark_saves->[0]{user_id},
    'user-1', 'save_bookmark scopes the write to the member' );

my $failed_bookmark = $workflow->save_bookmark(
    {
        command_id  => 'bookmark-failed-1',
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'boom',
    }
);
is( $failed_bookmark->{status},
    'failed', 'save_bookmark maps store exceptions to failed' );

my $removed = $workflow->remove_bookmark(
    {
        command_id  => 'bookmark-remove-1',
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'user-1',
    }
);
ok( $removed->{ok}, 'remove_bookmark succeeds for a known bookmark' );

my $missing_remove = $workflow->remove_bookmark(
    {
        command_id  => 'bookmark-remove-gone-1',
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'gone',
    }
);
is( $missing_remove->{status},
    'not_found', 'remove_bookmark maps a missing row to not_found' );

my $subscribed = $workflow->save_subscription(
    {
        command_id  => 'subscribe-1',
        preference  => 'all',
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'user-1',
    }
);
ok( $subscribed->{ok}, 'save_subscription succeeds for a known member' );
is( $subscribed->{stored}{preference},
    'all', 'save_subscription returns the stored preference' );

my $muted = $workflow->mute_subscription(
    {
        command_id  => 'mute-1',
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'user-1',
    }
);
ok( $muted->{ok}, 'mute_subscription succeeds for a known subscription' );

my $revoked = $workflow->revoke_subscription(
    {
        command_id  => 'unsubscribe-1',
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'user-1',
    }
);
ok( $revoked->{ok}, 'revoke_subscription succeeds for a known subscription' );

my $missing_mute = $workflow->mute_subscription(
    {
        command_id  => 'mute-gone-1',
        target_id   => 'thread-1',
        target_type => 'thread',
        user_id     => 'gone',
    }
);
is( $missing_mute->{status},
    'not_found', 'mute_subscription maps a missing row to not_found' );

my $missing_report = $workflow->create_report(
    {
        details          => 'Thread report',
        reason           => 'spam',
        reporter_user_id => 'user-1',
        target_id        => 'thread-1',
        target_type      => 'thread',
    }
);
is( $missing_report->{status},
    'invalid', 'create_report rejects a missing command_id' );
is(
    $missing_report->{errors}{command_id},
    'command_id is required',
    'create_report names the missing command_id'
);

my $reported = $workflow->create_report(
    {
        command_id       => 'report-1',
        details          => 'Thread report',
        reason           => 'spam',
        reporter_user_id => 'user-1',
        target_id        => 'thread-1',
        target_type      => 'thread',
    }
);
ok( $reported->{ok}, 'create_report succeeds for a known member' );
is( $reported->{stored}{target_id},
    'thread-1', 'create_report returns the stored target' );
is( $services->report_creates->[0]{reporter_user_id},
    'user-1', 'create_report scopes the write to the reporter' );

my $invalid_reason = $workflow->create_report(
    {
        command_id       => 'report-invalid-1',
        reason           => q{},
        reporter_user_id => 'user-1',
        target_id        => 'thread-1',
        target_type      => 'thread',
    }
);
is( $invalid_reason->{status},
    'invalid', 'create_report rejects a missing reason' );
is(
    $invalid_reason->{errors}{reason},
    'reason is required',
    'create_report names the missing reason'
);

my $failed_report = $workflow->create_report(
    {
        command_id       => 'report-failed-1',
        reason           => 'spam',
        reporter_user_id => 'boom',
        target_id        => 'thread-1',
        target_type      => 'thread',
    }
);
is( $failed_report->{status},
    'failed', 'create_report maps store exceptions to failed' );

my $idempotency = GPForum::Test::CommandIdempotency->new;
my $commanded   = GPForum::Service::Community::Workflow->new(
    bookmark_store      => $services,
    command_idempotency => $idempotency,
    report_store        => $services,
    subscription_store  => $services,
);
_replay_community(
    {
        commanded    => $commanded,
        command_type => 'community.bookmark',
        counter      => 'bookmark_saves',
        idempotency  => $idempotency,
        input        => {
            command_id  => 'bookmark-replay-1',
            note        => 'later',
            target_id   => 'thread-1',
            target_type => 'thread',
            user_id     => 'user-1',
        },
        method  => 'save_bookmark',
        request => {
            note        => 'later',
            target_id   => 'thread-1',
            target_type => 'thread',
            user_id     => 'user-1',
        },
        services => $services,
    }
);
_replay_community(
    {
        commanded    => $commanded,
        command_type => 'community.subscribe',
        counter      => 'subscription_saves',
        idempotency  => $idempotency,
        input        => {
            command_id  => 'subscribe-replay-1',
            preference  => 'all',
            target_id   => 'thread-1',
            target_type => 'thread',
            user_id     => 'user-1',
        },
        method  => 'save_subscription',
        request => {
            preference  => 'all',
            target_id   => 'thread-1',
            target_type => 'thread',
            user_id     => 'user-1',
        },
        services => $services,
    }
);
_replay_community(
    {
        commanded    => $commanded,
        command_type => 'community.report',
        counter      => 'report_creates',
        idempotency  => $idempotency,
        input        => {
            command_id       => 'report-replay-1',
            details          => 'Thread report',
            reason           => 'spam',
            reporter_user_id => 'user-1',
            target_id        => 'thread-1',
            target_type      => 'thread',
        },
        method  => 'create_report',
        request => {
            details          => 'Thread report',
            reason           => 'spam',
            reporter_user_id => 'user-1',
            target_id        => 'thread-1',
            target_type      => 'thread',
        },
        services => $services,
    }
);

done_testing();

sub _store_writes {
    my ( $store, $counter ) = @_;

    return scalar @{ $store->$counter };
}

sub _replay_community {
    my ($job) = @_;

    my $method       = $job->{method};
    my $write_issued = $job->{commanded}->$method( $job->{input} );
    ok( $write_issued->{ok}, "$method records a command" );
    is( $job->{idempotency}->last_input->{command_type},
        $job->{command_type}, "$method uses $job->{command_type}" );
    is_deeply( $job->{idempotency}->last_input->{request},
        $job->{request}, "$method command log stores target and actor" );
    my $write_count    = _store_writes( $job->{services}, $job->{counter} );
    my $write_replayed = GPForum::Service::Community::Workflow->new(
        bookmark_store      => $job->{services},
        command_idempotency => GPForum::Test::CommandIdempotency->new(
            replay_response => $write_issued,
        ),
        report_store       => $job->{services},
        subscription_store => $job->{services},
    )->$method( $job->{input} );
    is_deeply( $write_replayed, $write_issued,
        "$method replays the recorded result" );
    is( _store_writes( $job->{services}, $job->{counter} ),
        $write_count, "$method replay does not persist twice" );
    my $write_conflict = GPForum::Service::Community::Workflow->new(
        bookmark_store      => $job->{services},
        command_idempotency => GPForum::Test::CommandIdempotency->new(
            conflict => 1,
        ),
        report_store       => $job->{services},
        subscription_store => $job->{services},
    )->$method( $job->{input} );
    is( $write_conflict->{status},
        'conflict', "$method rejects a reused command_id for another request" );

    return;
}

1;
