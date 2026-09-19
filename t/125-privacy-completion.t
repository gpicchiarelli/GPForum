package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Privacy::Completion;
use GPForum::Service::Privacy::Record;
use Test::More;

our $VERSION = '0.001';

my $completion = GPForum::Service::Privacy::Completion->new;
ok(
    !$completion->job_done( { status => 'pending' } ),
    'job_done rejects a pending erasure job'
);
ok(
    $completion->job_done( { status => 'done' } ),
    'job_done accepts a completed erasure job'
);

my $job = {
    completed_at        => undef,
    deletion_request_id => 'del-1',
    erasure_job_id      => 'job-1',
    last_error          => undef,
    scheduled_at        => '2026-09-19T12:00:00Z',
    status              => 'pending',
};
is_deeply(
    $completion->approval_replay( 'del-1', $job ),
    {
        idempotent => 1,
        job        => GPForum::Service::Privacy::Record->new->job_hash($job),
        ok         => 1,
        request_id => 'del-1',
    },
    'approval_replay keeps the existing job hash'
);
is_deeply(
    $completion->completion_replay('job-1'),
    {
        erasure_job_id => 'job-1',
        idempotent     => 1,
        ok             => 1,
    },
    'completion_replay marks a done job as idempotent'
);
is_deeply(
    $completion->skipped('resource_not_user'),
    { skipped => 'resource_not_user' },
    'skipped keeps the named erasure skip reason'
);
is(
    $completion->hold_reason(undef),
    'active legal hold',
    'hold_reason defaults an empty caller reason'
);
is( $completion->hold_reason('staff review'),
    'staff review', 'hold_reason keeps an explicit caller reason' );

done_testing();

1;
