package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Privacy::DataRightsReview;
use GPForum::Service::Privacy::DeletionWorkflow;
use GPForum::Service::Privacy::RetentionHoldStore;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;
use GPForum::Test::PostStoreLockDbh;
use GPForum::Test::PostStoreLockStorage;

our $VERSION = '0.001';

const my $ONE_ROW              => 1;
const my $TWO_ROWS             => 2;
const my $REVIEW_LIMIT         => 25;
const my $SUBJECT_USER_ID      => '00000000-0000-7000-8000-000000000001';
const my $HELD_USER_ID         => '00000000-0000-7000-8000-000000000002';
const my $ERASURE_HELD_USER_ID => '00000000-0000-7000-8000-000000000003';

my $deletion_requests =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $deletion_actions = GPForum::Test::ModerationResultSet->new;
my $erasure_jobs =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $retention_holds =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $event_log       = GPForum::Test::ModerationResultSet->new;
my $outbox_messages = GPForum::Test::ModerationResultSet->new;
my $audit_log       = GPForum::Test::ModerationResultSet->new;
my $users           = GPForum::Test::ModerationResultSet->new;
my $credentials = GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $sessions    = GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $approval_lock_dbh = GPForum::Test::PostStoreLockDbh->new;
my $schema            = GPForum::Test::ModerationSchema->new(
    resultsets => {
        AuditLog        => $audit_log,
        Credential      => $credentials,
        DeletionAction  => $deletion_actions,
        DeletionRequest => $deletion_requests,
        ErasureJob      => $erasure_jobs,
        EventLog        => $event_log,
        OutboxMessage   => $outbox_messages,
        RetentionHold   => $retention_holds,
        Session         => $sessions,
        User            => $users,
    },
    storage => GPForum::Test::PostStoreLockStorage->new(
        dbh => $approval_lock_dbh,
    ),
);

_seed_user( $users, $SUBJECT_USER_ID );
_seed_user( $users, $HELD_USER_ID );
_seed_user( $users, $ERASURE_HELD_USER_ID );
$credentials->create(
    {
        id         => 'credential-1',
        revoked_at => undef,
        user_id    => $SUBJECT_USER_ID,
    }
);
$sessions->create(
    {
        id         => 'session-1',
        revoked_at => undef,
        user_id    => $SUBJECT_USER_ID,
    }
);

my $clock    = GPForum::Test::FixedClock->new;
my $workflow = GPForum::Service::Privacy::DeletionWorkflow->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);

my $request = $workflow->request_deletion(
    {
        requester_user_id => $SUBJECT_USER_ID,
        resource_type     => 'user',
        resource_id       => $SUBJECT_USER_ID,
        request_type      => 'anonymize',
        reason            => 'user requested account deletion',
    }
);

is( $request->{deletion_request_id},
    'generated-1', 'deletion request id is generated' );
is( $request->{requester_user_id},
    $SUBJECT_USER_ID, 'deletion request stores requester' );
is( $request->{resource_type}, 'user',
    'deletion request stores resource type' );
is( $request->{resource_id},
    $SUBJECT_USER_ID, 'deletion request stores resource id' );
is( $request->{request_type},
    'anonymize', 'deletion request stores request type' );
is( $request->{status}, 'pending', 'deletion request starts pending' );
is( $request->{created_at},
    '2026-05-23T12:00:00Z', 'deletion request stores timestamp' );
is( scalar @{ $deletion_requests->created },
    $ONE_ROW, 'deletion request row is inserted' );
is( scalar @{ $event_log->created },
    $ONE_ROW, 'deletion request emits privacy event' );
is( $event_log->created->[0]{event_type},
    'privacy.deletion_requested', 'deletion request event is named' );
is( scalar @{ $outbox_messages->created },
    $ONE_ROW, 'deletion request enqueues outbox message' );
is( scalar @{ $audit_log->created },
    $ONE_ROW, 'deletion request writes audit row' );

my $approved =
  $workflow->approve_request( 'generated-1', 'admin-1',
    'verified account owner request' );
is( $approved->{request_id}, 'generated-1', 'approval returns request id' );
is( $approved->{action}{deletion_action_id},
    'generated-6', 'approval action id is generated after audit rows' );
is( $approved->{action}{actor_id}, 'admin-1', 'approval action stores actor' );
is( $approved->{action}{action_type},
    'released', 'approval records release action' );
is( $approved->{job}{erasure_job_id},
    'generated-7', 'erasure job id is generated' );
is( $approved->{job}{status}, 'pending', 'erasure job starts pending' );
is( $deletion_requests->find('generated-1')->get_column('status'),
    'approved', 'deletion request row is approved' );
is( scalar @{ $deletion_actions->created },
    $ONE_ROW, 'approval action is inserted' );
is( scalar @{ $erasure_jobs->created }, $ONE_ROW, 'erasure job is inserted' );
is( scalar @{ $audit_log->created },
    $TWO_ROWS, 'approval writes an audit row' );
is(
    $approval_lock_dbh->calls->[0]{sql},
'SELECT deletion_request_id FROM deletion_requests WHERE deletion_request_id = ? FOR UPDATE',
    'approval locks the deletion request row before creating erasure job'
);
is_deeply( $approval_lock_dbh->calls->[0]{bind},
    ['generated-1'], 'approval lock targets the deletion request id' );

my $approved_again =
  $workflow->approve_request( 'generated-1', 'admin-1',
    'retry after network timeout' );
ok( $approved_again->{idempotent}, 'repeated approval reuses existing job' );
is( $approved_again->{job}{erasure_job_id},
    'generated-7', 'repeated approval returns the original erasure job' );
is( scalar @{ $erasure_jobs->created },
    $ONE_ROW, 'repeated approval avoids duplicate erasure jobs' );
is( scalar @{ $deletion_actions->created },
    $ONE_ROW, 'repeated approval avoids duplicate deletion actions' );

my $completed = $workflow->complete_job( 'generated-7', 'worker-1' );
is( $completed->{erasure_job_id}, 'generated-7', 'completion returns job id' );
is( $completed->{action}{deletion_action_id},
    'generated-12', 'completion action id is generated' );
is( $completed->{action}{action_type},
    'anonymized', 'completion records anonymization action' );
is( $erasure_jobs->find('generated-7')->get_column('status'),
    'done', 'erasure job row is completed' );
is( $deletion_requests->find('generated-1')->get_column('status'),
    'completed', 'deletion request row is completed' );
is(
    $users->find($SUBJECT_USER_ID)->get_column('display_name'),
    'Deleted member',
    'erasure anonymizes public display name'
);
is(
    $users->find($SUBJECT_USER_ID)->get_column('email_normalized'),
    'deleted+00000000000070008000000000000001@example.invalid',
    'erasure replaces private email with invalid tombstone'
);
is( $credentials->find('credential-1')->get_column('revoked_at'),
    '2026-05-23T12:00:00Z', 'erasure revokes credentials' );
is( $sessions->find('session-1')->get_column('revoked_at'),
    '2026-05-23T12:00:00Z', 'erasure revokes sessions' );
is( scalar @{ $deletion_actions->created },
    $TWO_ROWS, 'completion action is inserted' );

my $completed_again = $workflow->complete_job( 'generated-7', 'worker-1' );
ok( $completed_again->{idempotent}, 'completed erasure job is idempotent' );
is( scalar @{ $deletion_actions->created },
    $TWO_ROWS, 'idempotent completion avoids duplicate actions' );

my $holds = GPForum::Service::Privacy::RetentionHoldStore->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);
my $hold = $holds->create_hold(
    {
        resource_type => 'user',
        resource_id   => $HELD_USER_ID,
        reason        => 'legal investigation',
        created_by    => 'admin-2',
    }
);
is( $hold->{retention_hold_id},
    'generated-1', 'retention hold id is generated' );
is( $hold->{resource_type}, 'user', 'retention hold stores resource type' );
is( $hold->{reason}, 'legal investigation', 'retention hold stores reason' );
is( $hold->{created_by}, 'admin-2',         'retention hold stores creator' );
is( scalar @{ $retention_holds->created },
    $ONE_ROW, 'retention hold row is inserted' );
is(
    $audit_log->created->[-1]{action},
    'privacy.retention_hold_created',
    'retention hold is audited'
);

my $blocked_request = $workflow->request_deletion(
    {
        requester_user_id => 'user-2',
        resource_type     => 'user',
        resource_id       => $HELD_USER_ID,
        request_type      => 'anonymize',
        reason            => 'delete held account',
    }
);
my $blocked = $workflow->approve_request(
    $blocked_request->{deletion_request_id},
    'admin-3', 'legal hold active',
);
ok( !$blocked->{ok}, 'active legal hold blocks deletion approval' );
is( $blocked->{error},
    'retention_hold_active', 'blocked approval reports hold error' );
is(
    $deletion_requests->find( $blocked_request->{deletion_request_id} )
      ->get_column('status'),
    'held',
    'blocked approval marks request held'
);
is( scalar @{ $erasure_jobs->created },
    $ONE_ROW, 'blocked approval does not create an erasure job' );

my $job_hold_request = $workflow->request_deletion(
    {
        requester_user_id => 'user-3',
        resource_type     => 'user',
        resource_id       => $ERASURE_HELD_USER_ID,
        request_type      => 'anonymize',
        reason            => 'delete account after review',
    }
);
my $job_hold_approval = $workflow->approve_request(
    $job_hold_request->{deletion_request_id},
    'admin-4', 'approved before later hold',
);
my $job_hold = $holds->create_hold(
    {
        resource_type => 'user',
        resource_id   => $ERASURE_HELD_USER_ID,
        reason        => 'preserve evidence',
        created_by    => 'admin-4',
    }
);
my $blocked_job =
  $workflow->complete_job( $job_hold_approval->{job}{erasure_job_id},
    'worker-2', );
ok( !$blocked_job->{ok}, 'active legal hold blocks erasure job' );
is( $blocked_job->{error},
    'retention_hold_active', 'blocked erasure reports hold error' );
is(
    $erasure_jobs->find( $job_hold_approval->{job}{erasure_job_id} )
      ->get_column('last_error'),
    'retention hold active',
    'blocked erasure stores retryable job error'
);
is(
    $deletion_requests->find( $job_hold_request->{deletion_request_id} )
      ->get_column('status'),
    'held',
    'blocked erasure marks request held'
);
is( $job_hold->{resource_id},
    $ERASURE_HELD_USER_ID, 'second legal hold targets later erasure subject' );

my $active_holds =
  $holds->active_holds_for( 'user', $HELD_USER_ID, $REVIEW_LIMIT );
is( scalar @{$active_holds}, $ONE_ROW, 'active holds can be listed' );
is( $retention_holds->last_attrs->{rows},
    $REVIEW_LIMIT, 'active holds apply limit' );

my $review =
  GPForum::Service::Privacy::DataRightsReview->new( schema => $schema );
my $pending = $review->pending_deletion_requests( { limit => $REVIEW_LIMIT } );
is( scalar @{$pending},
    0, 'completed and held requests are absent from pending review' );
is( $deletion_requests->last_query->{status},
    'pending', 'pending review filters by status' );
is( $deletion_requests->last_attrs->{rows},
    $REVIEW_LIMIT, 'pending review applies limit' );
is(
    $review->deletion_request('generated-1')->get_column('deletion_request_id'),
    'generated-1', 'review can load one deletion request'
);

my $subject_requests =
  $review->deletion_requests_for_user( $SUBJECT_USER_ID,
    { limit => $REVIEW_LIMIT } );
is( scalar @{$subject_requests},
    $ONE_ROW, 'user dashboard lists own deletion requests' );

my $subject_holds =
  $review->active_holds_for_user( $HELD_USER_ID, { limit => $REVIEW_LIMIT } );
is( scalar @{$subject_holds}, $ONE_ROW, 'user dashboard lists active holds' );

my $all_holds = $review->active_holds( { limit => $REVIEW_LIMIT } );
is( scalar @{$all_holds}, 2, 'staff review lists active holds' );

my $done_jobs =
  $review->erasure_jobs_by_status( 'done', { limit => $REVIEW_LIMIT } );
is( scalar @{$done_jobs}, $ONE_ROW, 'completed erasure jobs can be reviewed' );
is( $erasure_jobs->last_query->{status}, 'done', 'job review filters status' );
is( $erasure_jobs->last_attrs->{rows},
    $REVIEW_LIMIT, 'job review applies limit' );

done_testing();

sub _seed_user {
    my ( $users, $user_id ) = @_;

    $users->create(
        {
            id                => $user_id,
            username          => 'member-' . substr( $user_id, -1 ),
            display_name      => 'Forum member',
            email_normalized  => $user_id . '@example.test',
            password_hash     => 'hashed',
            status            => 'active',
            trust_level       => 1,
            email_verified_at => '2026-05-23T12:00:00Z',
            updated_at        => '2026-05-23T12:00:00Z',
            deleted_at        => undef,
        }
    );

    return;
}

1;
