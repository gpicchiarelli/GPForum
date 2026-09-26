# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Service::Moderation::Event;
use Test::More;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;

my $events = GPForum::Service::Moderation::Event->new;
my $action = {
    action_type          => 'post.hidden',
    actor_user_id        => 'mod-1',
    created_at           => '2026-09-19T12:00:00Z',
    metadata             => { idempotent => 0 },
    moderation_action_id => 'act-1',
    reason               => 'spam',
    target_id            => 'post-1',
    target_type          => 'post',
};

is_deeply(
    $events->action_payload($action),
    {
        metadata             => { idempotent => 0 },
        moderation_action_id => 'act-1',
        reason               => 'spam',
        target_id            => 'post-1',
        target_type          => 'post',
    },
    'action_payload keeps action fields'
);

my $recorded = {
    action         => $action,
    correlation_id => 'corr-1',
};
my $envelope = $events->action_envelope($recorded);
is( $envelope->{event_type},
    'post.hidden', 'action_envelope uses the action type' );
is( $envelope->{aggregate_type},
    'post', 'action_envelope uses the target type' );
is( $envelope->{aggregate_version},
    $SCHEMA_VERSION, 'action_envelope uses schema version 1' );
is(
    $envelope->{idempotency_key},
    'post.hidden:post:post-1:act-1',
    'action_envelope keys idempotency on type, target, and action id'
);

my $audit = $events->action_audit($recorded);
is( $audit->{action}, 'post.hidden', 'action_audit uses the action type' );
is( $audit->{metadata}{moderation_action_id},
    'act-1', 'action_audit records the moderation action id' );

my $reversal = {
    action              => $action,
    action_id           => 'act-1',
    correlation_id      => 'corr-2',
    reason              => 'false positive',
    reversed_at         => '2026-09-19T12:01:00Z',
    reversed_by         => 'mod-2',
    reversed_by_user_id => 'mod-2',
};
is_deeply(
    $events->reversal_payload($reversal),
    {
        moderation_action_id => 'act-1',
        original_action_type => 'post.hidden',
        reason               => 'false positive',
        reversed_at          => '2026-09-19T12:01:00Z',
        reversed_by_user_id  => 'mod-2',
        target_id            => 'post-1',
        target_type          => 'post',
    },
    'reversal_payload keeps reversal fields'
);

my $reversed = $events->reversal_envelope($reversal);
is( $reversed->{event_type},
    'moderation_action.reversed', 'reversal_envelope uses the reversed type' );
is( $reversed->{aggregate_type},
    'moderation_action', 'reversal_envelope targets the action aggregate' );
is(
    $reversed->{idempotency_key},
    'moderation_action.reversed:act-1',
    'reversal_envelope keys idempotency on the action id'
);

my $reversal_audit = $events->reversal_audit($reversal);
is( $reversal_audit->{action},
    'moderation_action.reversed', 'reversal_audit uses the reversed action' );
is( $reversal_audit->{actor_id},
    'mod-2', 'reversal_audit records the reversing actor' );
is( $reversal_audit->{metadata}{original_action_type},
    'post.hidden', 'reversal_audit keeps the original action type' );

my $report = {
    created_at       => '2026-09-19T12:02:00Z',
    reason           => 'spam',
    report_id        => 'rep-1',
    reporter_user_id => 'user-1',
    target_id        => 'post-1',
    target_type      => 'post',
};
is_deeply(
    $events->report_created_payload($report),
    {
        reason      => 'spam',
        report_id   => 'rep-1',
        target_id   => 'post-1',
        target_type => 'post',
    },
    'report_created_payload keeps report fields'
);

my $created = {
    correlation_id => 'corr-3',
    report         => $report,
};
my $created_envelope = $events->report_created_envelope($created);
is( $created_envelope->{event_type},
    'report.created', 'report_created_envelope uses the created type' );
is( $created_envelope->{idempotency_key},
    'report.created:rep-1',
    'report_created_envelope keys idempotency on the report id' );
is( $created_envelope->{aggregate_type},
    'report', 'report_created_envelope uses the report aggregate' );

my $created_audit = $events->report_created_audit($created);
is( $created_audit->{action},
    'report.created', 'report_created_audit uses the created action' );
is( $created_audit->{metadata}{report_id},
    'rep-1', 'report_created_audit records the report id' );

my $duplicate_audit = $events->report_duplicate_audit(
    {
        created_at       => '2026-09-19T12:03:00Z',
        duplicate        => $report,
        reason           => 'spam',
        reporter_user_id => 'user-1',
        target_id        => 'post-1',
        target_type      => 'post',
    }
);
is( $duplicate_audit->{action},
    'report.duplicate_blocked',
    'report_duplicate_audit uses the duplicate action' );
is( $duplicate_audit->{metadata}{existing_report_id},
    'rep-1', 'report_duplicate_audit records the existing report id' );

my $transition = {
    actor_id       => 'mod-1',
    correlation_id => 'corr-4',
    created_at     => '2026-09-19T12:04:00Z',
    event_id       => 'evt-1',
    event_type     => 'report.assigned',
    payload        => { assigned_moderator_user_id => 'mod-1' },
    report         => $report,
};
my $transition_envelope = $events->report_transition_envelope($transition);
is( $transition_envelope->{event_id},
    'evt-1', 'report_transition_envelope keeps the allocated event id' );
is( $transition_envelope->{idempotency_key},
    'report.assigned:rep-1:evt-1',
    'report_transition_envelope keys idempotency on type, report, and event' );
is( $transition_envelope->{payload}{assigned_moderator_user_id},
    'mod-1', 'report_transition_envelope merges the transition payload' );

my $transition_audit = $events->report_transition_audit(
    {
        action         => 'report.assigned',
        actor_id       => 'mod-1',
        correlation_id => 'corr-4',
        created_at     => '2026-09-19T12:04:00Z',
        metadata       => { assigned_moderator_user_id => 'mod-1' },
        report         => $report,
    }
);
is( $transition_audit->{action},
    'report.assigned', 'report_transition_audit uses the transition action' );
is( $transition_audit->{metadata}{report_id},
    'rep-1', 'report_transition_audit records the report id' );
is( $transition_audit->{metadata}{assigned_moderator_user_id},
    'mod-1', 'report_transition_audit keeps transition metadata' );

my $suspended = {
    action         => 'user.suspended',
    actor_id       => 'mod-1',
    correlation_id => 'corr-5',
    created_at     => '2026-09-19T12:05:00Z',
    metadata       => {
        previous_status => 'active',
        reason          => 'abuse',
        suspension_id   => 'sus-1',
    },
    payload => {
        reason        => 'abuse',
        suspension_id => 'sus-1',
        valid_from    => '2026-09-19T12:05:00Z',
        valid_to      => undef,
    },
    user_id => 'user-2',
};
my $suspension_envelope = $events->suspension_envelope($suspended);
is( $suspension_envelope->{event_type},
    'user.suspended', 'suspension_envelope uses the suspend type' );
is( $suspension_envelope->{aggregate_type},
    'user', 'suspension_envelope uses the user aggregate' );
is(
    $suspension_envelope->{idempotency_key},
    'user.suspended:user-2:2026-09-19T12:05:00Z',
    'suspension_envelope keys idempotency on action, user, and time'
);
is_deeply( $suspension_envelope->{payload},
    $suspended->{payload}, 'suspension_envelope keeps the supplied payload' );

my $suspension_audit = $events->suspension_audit($suspended);
is( $suspension_audit->{action},
    'user.suspended', 'suspension_audit uses the suspend action' );
is( $suspension_audit->{target_id},
    'user-2', 'suspension_audit targets the user id' );
is( $suspension_audit->{metadata}{suspension_id},
    'sus-1', 'suspension_audit records the suspension id' );

my $revoked = {
    action         => 'user.suspension_revoked',
    actor_id       => 'mod-2',
    correlation_id => 'corr-6',
    created_at     => '2026-09-19T12:06:00Z',
    metadata       => {
        reason        => 'appeal',
        suspension_id => 'sus-1',
    },
    payload => {
        reason        => 'appeal',
        revoked_at    => '2026-09-19T12:06:00Z',
        suspension_id => 'sus-1',
    },
    user_id => 'user-2',
};
is( $events->suspension_envelope($revoked)->{event_type},
    'user.suspension_revoked', 'suspension_envelope uses the revoke type' );
is( $events->suspension_audit($revoked)->{action},
    'user.suspension_revoked', 'suspension_audit uses the revoke action' );

done_testing();

1;
