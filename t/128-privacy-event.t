package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Service::Privacy::Event;
use GPForum::Service::Privacy::Record;
use Test::More;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;

my $events  = GPForum::Service::Privacy::Event->new;
my $records = GPForum::Service::Privacy::Record->new;
my $request = {
    created_at          => '2026-09-19T12:00:00Z',
    deletion_request_id => 'del-1',
    reason              => 'please delete',
    request_type        => 'erasure',
    resource_id         => 'user-1',
    resource_type       => 'user',
    status              => 'pending',
};
my $payload = $records->request_payload($request);

is(
    $events->block_error,
    'retention hold active',
    'block_error keeps the hold last_error text'
);

my $requested = $events->requested(
    {
        actor_id => 'user-1',
        request  => $request,
    }
);
is( $requested->{action},
    'privacy.deletion_requested', 'requested uses the request event type' );
is( $requested->{idempotency},
    'del-1', 'requested keys idempotency on the request id' );
is_deeply( $requested->{payload},
    $payload, 'requested keeps the request payload' );

my $approved = $events->approved(
    {
        action     => { deletion_action_id => 'act-1' },
        actor_id   => 'mod-1',
        job        => { erasure_job_id => 'job-1' },
        reason     => undef,
        request    => $request,
        request_id => 'del-1',
        timestamp  => '2026-09-19T12:01:00Z',
    }
);
is( $approved->{action},
    'privacy.deletion_approved', 'approved uses the approval event type' );
is( $approved->{idempotency},
    'del-1:approved', 'approved suffixes the request id' );
is( $approved->{metadata}{reason},
    q{}, 'approved defaults a missing reason to empty text' );
is( $approved->{payload}{erasure_job_id},
    'job-1', 'approved adds the erasure job id' );

my $blocked = $events->blocked(
    {
        action         => { deletion_action_id => 'act-2' },
        actor_id       => 'mod-1',
        erasure_job_id => 'job-1',
        request        => $request,
        timestamp      => '2026-09-19T12:02:00Z',
    }
);
is( $blocked->{action},
    'privacy.erasure_blocked', 'blocked uses the block event type' );
is( $blocked->{metadata}{reason},
    $events->block_error, 'blocked reuses the hold last_error text' );

my $completed = $events->completed(
    {
        action         => { deletion_action_id => 'act-3' },
        actor_id       => 'mod-1',
        anonymized     => { skipped => 'resource_not_user' },
        erasure_job_id => 'job-1',
        request        => $request,
        timestamp      => '2026-09-19T12:03:00Z',
    }
);
is( $completed->{action},
    'privacy.erasure_completed', 'completed uses the done event type' );
is_deeply(
    $completed->{payload}{anonymized},
    { skipped => 'resource_not_user' },
    'completed keeps the anonymized result'
);

my $held = $events->held(
    {
        actor_id  => 'mod-1',
        reason    => 'staff review',
        request   => $request,
        timestamp => '2026-09-19T12:04:00Z',
    }
);
is( $held->{action}, 'privacy.deletion_held', 'held uses the hold event type' );
is( $held->{idempotency}, 'del-1:held',       'held suffixes the request id' );

my $envelope = $events->envelope( $requested, 'corr-1' );
is( $envelope->{aggregate_type},
    'user', 'envelope uses the request resource type' );
is(
    $envelope->{idempotency_key},
    'privacy.deletion_requested:del-1',
    'envelope joins action and idempotency'
);
is( $envelope->{correlation_id},
    'corr-1', 'envelope keeps the supplied correlation id' );
is( $envelope->{aggregate_version},
    $SCHEMA_VERSION, 'envelope uses schema version 1 as aggregate version' );

my $audit = $events->audit( $approved, 'corr-2' );
is( $audit->{schema_version}, $SCHEMA_VERSION, 'audit uses schema version 1' );
is( $audit->{target_id},      'user-1', 'audit targets the resource id' );
is( $audit->{metadata}{deletion_request_id},
    'del-1', 'audit records the deletion request id' );
is( $audit->{metadata}{deletion_action_id},
    'act-1', 'audit keeps event metadata beside the request id' );

my $hold = {
    created_at        => '2026-09-19T12:05:00Z',
    ends_at           => undef,
    reason            => 'staff review',
    resource_id       => 'user-1',
    resource_type     => 'user',
    retention_hold_id => 'hold-1',
    starts_at         => '2026-09-19T12:05:00Z',
};
is_deeply(
    $events->hold_payload($hold),
    {
        ends_at           => undef,
        reason            => 'staff review',
        resource_id       => 'user-1',
        resource_type     => 'user',
        retention_hold_id => 'hold-1',
        starts_at         => '2026-09-19T12:05:00Z',
    },
    'hold_payload keeps hold fields'
);

my $hold_recorded = {
    actor_id       => 'mod-1',
    correlation_id => 'corr-3',
    hold           => $hold,
};
my $hold_envelope = $events->hold_envelope($hold_recorded);
is(
    $hold_envelope->{event_type},
    'privacy.retention_hold_created',
    'hold_envelope uses the created-hold event type'
);
is(
    $hold_envelope->{idempotency_key},
    'privacy.retention_hold_created:hold-1',
    'hold_envelope keys idempotency on the hold id'
);
is( $hold_envelope->{aggregate_version},
    $SCHEMA_VERSION,
    'hold_envelope uses schema version 1 as aggregate version' );

my $hold_audit = $events->hold_audit($hold_recorded);
is(
    $hold_audit->{action},
    'privacy.retention_hold_created',
    'hold_audit uses the created-hold action'
);
is( $hold_audit->{metadata}{retention_hold_id},
    'hold-1', 'hold_audit records the retention hold id' );
is( $hold_audit->{target_id}, 'user-1', 'hold_audit targets the resource id' );

done_testing();

1;
