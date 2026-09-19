package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Privacy::Workflow;
use GPForum::Test::PrivacyWebServices;
use Test::More;

our $VERSION = '0.001';

my $services = GPForum::Test::PrivacyWebServices->new;
my $workflow = GPForum::Service::Privacy::Workflow->new(
    deletion_workflow => $services,
    export_builder    => $services,
    hold_store        => $services,
    reviewer          => $services,
);

my $exported = $workflow->request_export( { user_id => 'user-1' } );
ok( $exported->{ok}, 'request_export succeeds for a known user' );
is( $exported->{stored}{export_request_id},
    'export-created', 'request_export returns the completed export' );

my $requested = $workflow->request_deletion(
    {
        reason  => 'leaving service',
        user_id => 'user-1',
    }
);
ok( $requested->{ok}, 'request_deletion succeeds when a reason is present' );
is( $requested->{stored}{request_type},
    'anonymize', 'request_deletion stores an anonymize request' );

my $missing_reason = $workflow->request_deletion(
    {
        reason  => q{},
        user_id => 'user-1',
    }
);
is( $missing_reason->{status},
    'invalid', 'request_deletion rejects an empty reason' );
is(
    $missing_reason->{errors}{reason},
    'reason is required',
    'request_deletion names the missing field'
);

my $approved = $workflow->approve_deletion(
    {
        actor_user_id => 'staff-1',
        reason        => 'reviewed',
        request_id    => 'delete-1',
    }
);
ok( $approved->{ok}, 'approve_deletion succeeds for a known request' );

my $missing_request = $workflow->approve_deletion(
    {
        actor_user_id => 'staff-1',
        reason        => 'reviewed',
        request_id    => 'missing',
    }
);
is( $missing_request->{status},
    'not_found', 'approve_deletion maps a missing request to not_found' );

my $held = $workflow->hold_deletion(
    {
        actor_user_id => 'staff-1',
        reason        => 'legal hold',
        request_id    => 'delete-1',
    }
);
ok( $held->{ok}, 'hold_deletion succeeds for a known request' );
is( $held->{stored}{action}{action_type},
    'held', 'hold_deletion records a held action' );

my $missing_hold = $workflow->hold_deletion(
    {
        actor_user_id => 'staff-1',
        reason        => 'legal hold',
        request_id    => 'missing',
    }
);
is( $missing_hold->{status},
    'not_found', 'hold_deletion maps a missing request to not_found' );

my $erased = $workflow->run_erasure_job(
    {
        actor_user_id => 'staff-1',
        job_id        => 'job-1',
    }
);
ok( $erased->{ok}, 'run_erasure_job succeeds for a known job' );

my $blocked = $workflow->run_erasure_job(
    {
        actor_user_id => 'staff-1',
        job_id        => 'job-held',
    }
);
is( $blocked->{status},
    'conflict', 'run_erasure_job maps an active hold to conflict' );

my $missing_job = $workflow->run_erasure_job(
    {
        actor_user_id => 'staff-1',
        job_id        => 'missing',
    }
);
is( $missing_job->{status},
    'not_found', 'run_erasure_job maps a missing job to not_found' );

done_testing();

1;
