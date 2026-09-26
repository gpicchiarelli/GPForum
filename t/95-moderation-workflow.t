# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Moderation::Workflow;
use GPForum::Test::CommandIdempotency;
use GPForum::Test::ForumWebServices;
use Test::More;

our $VERSION = '0.001';

my $workflow = GPForum::Service::Moderation::Workflow->new(
    action_store     => GPForum::Test::ForumWebServices->new,
    report_store     => GPForum::Test::ForumWebServices->new,
    suspension_store => GPForum::Test::ForumWebServices->new,
);

my $hidden = $workflow->hide_post(
    {
        actor_user_id => 'moderator-1',
        command_id    => 'hide-command-1',
        post_id       => 'post-1',
        reason        => 'spam',
    }
);
ok( $hidden->{ok}, 'hide_post succeeds for a known post' );
is( $hidden->{stored}{action}{action_type},
    'post.hidden', 'hide_post returns the stored action' );

my $missing_reason = $workflow->hide_post(
    {
        actor_user_id => 'moderator-1',
        post_id       => 'post-1',
        reason        => q{},
    }
);
is( $missing_reason->{status}, 'invalid', 'hide_post rejects an empty reason' );
is(
    $missing_reason->{errors}{reason},
    'reason is required',
    'hide_post names the missing reason'
);

my $missing_hide_command = $workflow->hide_post(
    {
        actor_user_id => 'moderator-1',
        post_id       => 'post-1',
        reason        => 'spam',
    }
);
is( $missing_hide_command->{status},
    'invalid', 'hide_post rejects a missing command_id' );
is(
    $missing_hide_command->{errors}{command_id},
    'command_id is required',
    'hide_post names the missing command_id'
);

my $missing_post = $workflow->hide_post(
    {
        actor_user_id => 'moderator-1',
        command_id    => 'missing-hide-command-1',
        post_id       => 'missing',
        reason        => 'spam',
    }
);
is( $missing_post->{status},
    'not_found', 'hide_post maps a missing post to not_found' );

my $hidden_thread = $workflow->hide_thread(
    {
        actor_user_id => 'moderator-1',
        command_id    => 'hide-thread-command-1',
        reason        => 'off-topic',
        thread_id     => 'thread-1',
    }
);
ok( $hidden_thread->{ok}, 'hide_thread succeeds for a known thread' );
is( $hidden_thread->{stored}{action}{action_type},
    'thread.hidden', 'hide_thread returns the stored action' );

my $missing_thread_reason = $workflow->hide_thread(
    {
        actor_user_id => 'moderator-1',
        reason        => q{},
        thread_id     => 'thread-1',
    }
);
is( $missing_thread_reason->{status},
    'invalid', 'hide_thread rejects an empty reason' );

my $missing_thread = $workflow->hide_thread(
    {
        actor_user_id => 'moderator-1',
        command_id    => 'missing-hide-thread-command-1',
        reason        => 'off-topic',
        thread_id     => 'missing',
    }
);
is( $missing_thread->{status},
    'not_found', 'hide_thread maps a missing thread to not_found' );

my $restored_thread = $workflow->restore_thread(
    {
        actor_user_id => 'moderator-1',
        command_id    => 'restore-thread-command-1',
        reason        => 'cleared',
        thread_id     => 'thread-1',
    }
);
ok( $restored_thread->{ok}, 'restore_thread succeeds for a known thread' );

my $assigned = $workflow->assign_report(
    {
        actor_user_id => 'moderator-1',
        command_id    => 'assign-command-1',
        report_id     => 'report-1',
    }
);
ok( $assigned->{ok}, 'assign_report succeeds for a known report' );

my $missing_assign_command = $workflow->assign_report(
    {
        actor_user_id => 'moderator-1',
        report_id     => 'report-1',
    }
);
is( $missing_assign_command->{status},
    'invalid', 'assign_report rejects a missing command_id' );
is(
    $missing_assign_command->{errors}{command_id},
    'command_id is required',
    'assign_report names the missing command_id'
);

my $missing_report = $workflow->assign_report(
    {
        actor_user_id => 'moderator-1',
        command_id    => 'missing-assign-command-1',
        report_id     => 'missing',
    }
);
is( $missing_report->{status},
    'not_found', 'assign_report maps a missing report to not_found' );

my $missing_resolution = $workflow->resolve_report(
    {
        actor_user_id => 'moderator-1',
        report_id     => 'report-1',
        resolution    => q{},
    }
);
is( $missing_resolution->{status},
    'invalid', 'resolve_report rejects an empty resolution' );

my $missing_resolve_command = $workflow->resolve_report(
    {
        actor_user_id => 'moderator-1',
        report_id     => 'report-1',
        resolution    => 'handled',
    }
);
is( $missing_resolve_command->{status},
    'invalid', 'resolve_report rejects a missing command_id' );

my $resolved = $workflow->resolve_report(
    {
        actor_user_id => 'moderator-1',
        command_id    => 'resolve-command-1',
        report_id     => 'report-1',
        resolution    => 'handled',
    }
);
ok( $resolved->{ok}, 'resolve_report succeeds when a resolution is present' );

my $reversed = $workflow->reverse_action(
    {
        action_id     => 'action-post-hide',
        actor_user_id => 'moderator-1',
        command_id    => 'reverse-command-1',
        reason        => 'appeal accepted',
    }
);
ok( $reversed->{ok}, 'reverse_action succeeds when a command_id is present' );

my $missing_reverse_command = $workflow->reverse_action(
    {
        action_id     => 'action-post-hide',
        actor_user_id => 'moderator-1',
        reason        => 'appeal accepted',
    }
);
is( $missing_reverse_command->{status},
    'invalid', 'reverse_action rejects a missing command_id' );

my $missing_suspend_command = $workflow->suspend_user(
    {
        actor_user_id => 'moderator-1',
        reason        => 'abuse campaign',
        user_id       => 'user-2',
    }
);
is( $missing_suspend_command->{status},
    'invalid', 'suspend_user rejects a missing command_id' );
is(
    $missing_suspend_command->{errors}{command_id},
    'command_id is required',
    'suspend_user names the missing command_id'
);

my $suspended = $workflow->suspend_user(
    {
        actor_user_id => 'moderator-1',
        command_id    => 'suspend-command-1',
        reason        => 'abuse campaign',
        user_id       => 'user-2',
    }
);
ok( $suspended->{ok}, 'suspend_user succeeds for a known user' );
is( $suspended->{stored}{suspension}{user_id},
    'user-2', 'suspend_user returns the stored user' );

my $revoked = $workflow->revoke_suspension(
    {
        actor_user_id => 'moderator-1',
        command_id    => 'revoke-command-1',
        reason        => 'appeal accepted',
        suspension_id => 'suspension-1',
    }
);
ok( $revoked->{ok}, 'revoke_suspension succeeds for a known suspension' );

my $services    = GPForum::Test::ForumWebServices->new;
my $idempotency = GPForum::Test::CommandIdempotency->new;
my $commanded   = GPForum::Service::Moderation::Workflow->new(
    action_store        => $services,
    command_idempotency => $idempotency,
    report_store        => $services,
    suspension_store    => $services,
);
_replay_moderation(
    {
        commanded    => $commanded,
        command_type => 'moderation.suspend',
        counter      => 'suspension_creates',
        idempotency  => $idempotency,
        input        => {
            actor_user_id => 'moderator-1',
            command_id    => 'suspend-replay-1',
            reason        => 'abuse campaign',
            user_id       => 'user-2',
        },
        method  => 'suspend_user',
        request => {
            actor_user_id => 'moderator-1',
            reason        => 'abuse campaign',
            user_id       => 'user-2',
        },
        services => $services,
    }
);
_replay_moderation(
    {
        commanded    => $commanded,
        command_type => 'moderation.suspension_revoke',
        counter      => 'suspension_revokes',
        idempotency  => $idempotency,
        input        => {
            actor_user_id => 'moderator-1',
            command_id    => 'revoke-replay-1',
            reason        => 'appeal accepted',
            suspension_id => 'suspension-1',
        },
        method  => 'revoke_suspension',
        request => {
            actor_user_id => 'moderator-1',
            reason        => 'appeal accepted',
            suspension_id => 'suspension-1',
        },
        services => $services,
    }
);
_replay_moderation(
    {
        commanded    => $commanded,
        command_type => 'moderation.assign',
        counter      => 'report_assigns',
        idempotency  => $idempotency,
        input        => {
            actor_user_id => 'moderator-1',
            command_id    => 'assign-replay-1',
            report_id     => 'report-1',
        },
        method  => 'assign_report',
        request => {
            actor_user_id => 'moderator-1',
            report_id     => 'report-1',
        },
        services => $services,
    }
);
_replay_moderation(
    {
        commanded    => $commanded,
        command_type => 'moderation.reverse',
        counter      => 'action_reverses',
        idempotency  => $idempotency,
        input        => {
            action_id     => 'action-post-hide',
            actor_user_id => 'moderator-1',
            command_id    => 'reverse-replay-1',
            reason        => 'appeal accepted',
        },
        method  => 'reverse_action',
        request => {
            action_id     => 'action-post-hide',
            actor_user_id => 'moderator-1',
            reason        => 'appeal accepted',
        },
        services => $services,
    }
);
_replay_moderation(
    {
        commanded    => $commanded,
        command_type => 'moderation.hide_post',
        counter      => 'post_hides',
        idempotency  => $idempotency,
        input        => {
            actor_user_id => 'moderator-1',
            command_id    => 'hide-replay-1',
            post_id       => 'post-1',
            reason        => 'spam',
        },
        method  => 'hide_post',
        request => {
            actor_user_id => 'moderator-1',
            post_id       => 'post-1',
            reason        => 'spam',
        },
        services => $services,
    }
);

done_testing();

sub _store_writes {
    my ( $store, $counter ) = @_;

    return scalar @{ $store->$counter };
}

sub _replay_moderation {
    my ($job) = @_;

    my $method       = $job->{method};
    my $write_issued = $job->{commanded}->$method( $job->{input} );
    ok( $write_issued->{ok}, "$method records a command" );
    is( $job->{idempotency}->last_input->{command_type},
        $job->{command_type}, "$method uses $job->{command_type}" );
    is_deeply( $job->{idempotency}->last_input->{request},
        $job->{request}, "$method command log stores actor and target" );
    my $write_count    = _store_writes( $job->{services}, $job->{counter} );
    my $write_replayed = GPForum::Service::Moderation::Workflow->new(
        action_store        => $job->{services},
        command_idempotency => GPForum::Test::CommandIdempotency->new(
            replay_response => $write_issued,
        ),
        report_store     => $job->{services},
        suspension_store => $job->{services},
    )->$method( $job->{input} );
    is_deeply( $write_replayed, $write_issued,
        "$method replays the recorded result" );
    is( _store_writes( $job->{services}, $job->{counter} ),
        $write_count, "$method replay does not persist twice" );
    my $write_conflict = GPForum::Service::Moderation::Workflow->new(
        action_store        => $job->{services},
        command_idempotency => GPForum::Test::CommandIdempotency->new(
            conflict => 1,
        ),
        report_store     => $job->{services},
        suspension_store => $job->{services},
    )->$method( $job->{input} );
    is( $write_conflict->{status},
        'conflict', "$method rejects a reused command_id for another request" );

    return;
}

1;
