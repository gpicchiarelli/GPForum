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

my $request_again = $workflow->request_deletion(
    {
        requester_user_id => $SUBJECT_USER_ID,
        resource_type     => 'user',
        resource_id       => $SUBJECT_USER_ID,
        request_type      => 'anonymize',
        reason            => 'user requested account deletion again',
    }
);
is( $request_again->{deletion_request_id},
    'generated-1', 'retry reuses the open deletion request' );
is( scalar @{ $deletion_requests->created },
    $ONE_ROW, 'retry does not insert a second deletion request' );
is( scalar @{ $event_log->created },
    $ONE_ROW, 'retry does not emit a second deletion event' );

$deletion_requests->skip_search(1);
my $raced_deletion = $workflow->request_deletion(
    {
        requester_user_id => $SUBJECT_USER_ID,
        resource_type     => 'user',
        resource_id       => $SUBJECT_USER_ID,
        request_type      => 'anonymize',
        reason            => 'concurrent retry after lock miss',
    }
);
is( $raced_deletion->{deletion_request_id},
    'generated-1', 'unique race reuses the open deletion request' );
is( scalar @{ $deletion_requests->created },
    $ONE_ROW, 'unique race does not insert a second deletion request' );

my $deletion_pk_rows =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$deletion_pk_rows->create(
    {
        deletion_request_id => 'generated-1',
        reason              => 'other',
        request_type        => 'anonymize',
        requester_user_id   => 'other-user',
        resource_id         => 'other-user',
        resource_type       => 'user',
        status              => 'pending',
    }
);
my $deletion_pk_events = GPForum::Test::ModerationResultSet->new;
my $deletion_pk_outbox = GPForum::Test::ModerationResultSet->new;
my $deletion_pk_audits = GPForum::Test::ModerationResultSet->new;
my $deletion_pk_store  = GPForum::Service::Privacy::DeletionWorkflow->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog        => $deletion_pk_audits,
            DeletionRequest => $deletion_pk_rows,
            EventLog        => $deletion_pk_events,
            OutboxMessage   => $deletion_pk_outbox,
        },
    ),
);
my $deletion_pk = $deletion_pk_store->request_deletion(
    {
        reason            => 'user requested account deletion',
        request_type      => 'anonymize',
        requester_user_id => 'user-pk',
        resource_id       => 'user-pk',
        resource_type     => 'user',
    }
);
is( $deletion_pk->{deletion_request_id},
    'generated-2', 'unique deletion id collision remints the id' );
is( $deletion_pk->{resource_id},
    'user-pk', 'unique deletion id collision keeps this resource' );
is( scalar @{ $deletion_pk_rows->created },
    $TWO_ROWS, 'unique deletion id collision inserts this request' );
is( scalar @{ $deletion_pk_events->created },
    $ONE_ROW, 'unique deletion id collision records this created event' );

my $deletion_leftover_rows =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$deletion_leftover_rows->create(
    {
        deletion_request_id => 'generated-1',
        reason              => 'user requested account deletion',
        request_type        => 'anonymize',
        requester_user_id   => 'user-leftover',
        resource_id         => 'user-leftover',
        resource_type       => 'user',
        status              => 'pending',
    }
);
$deletion_leftover_rows->skip_search(1);
my $deletion_leftover_events = GPForum::Test::ModerationResultSet->new;
my $deletion_leftover_outbox = GPForum::Test::ModerationResultSet->new;
my $deletion_leftover_audits = GPForum::Test::ModerationResultSet->new;
my $deletion_leftover_store  = GPForum::Service::Privacy::DeletionWorkflow->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog        => $deletion_leftover_audits,
            DeletionRequest => $deletion_leftover_rows,
            EventLog        => $deletion_leftover_events,
            OutboxMessage   => $deletion_leftover_outbox,
        },
    ),
);
my $deletion_leftover = $deletion_leftover_store->request_deletion(
    {
        reason            => 'user requested account deletion',
        request_type      => 'anonymize',
        requester_user_id => 'user-leftover',
        resource_id       => 'user-leftover',
        resource_type     => 'user',
    }
);
is( $deletion_leftover->{deletion_request_id},
    'generated-1', 'leftover deletion id race keeps this request' );
is( $deletion_leftover->{resource_id},
    'user-leftover', 'leftover deletion id race keeps this resource' );
is( scalar @{ $deletion_leftover_rows->created },
    $ONE_ROW, 'leftover deletion id race does not insert a second request' );
is( scalar @{ $deletion_leftover_events->created },
    $ONE_ROW, 'leftover deletion id race inserts the missing event' );
is( scalar @{ $deletion_leftover_outbox->created },
    $ONE_ROW, 'leftover deletion id race inserts the missing outbox' );
is( scalar @{ $deletion_leftover_audits->created },
    $ONE_ROW, 'leftover deletion id race inserts the missing audit' );

my $approved =
  $workflow->approve_request( 'generated-1', 'admin-1',
    'verified account owner request' );
is( $approved->{request_id}, 'generated-1', 'approval returns request id' );
is( $approved->{action}{deletion_action_id},
    'generated-8', 'approval action id is generated after the erasure job' );
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
my ($approval_lock) = grep {
    $_->{sql} =~ m/WHERE [ ] deletion_request_id [ ] = [ ] [?] [ ] FOR/msx
} @{ $approval_lock_dbh->calls };
is(
    $approval_lock->{sql},
'SELECT deletion_request_id FROM deletion_requests WHERE deletion_request_id = ? FOR UPDATE',
    'approval locks the deletion request row before creating erasure job'
);
is_deeply( $approval_lock->{bind},
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

$erasure_jobs->skip_search(1);
my $raced_approval =
  $workflow->approve_request( 'generated-1', 'admin-1',
    'concurrent approval after lookup miss' );
ok( $raced_approval->{idempotent},
    'unique race reuses the existing erasure job' );
is( $raced_approval->{job}{erasure_job_id},
    'generated-7', 'unique race returns the original erasure job' );
is( scalar @{ $erasure_jobs->created },
    $ONE_ROW, 'unique race does not insert a second erasure job' );
is( scalar @{ $deletion_actions->created },
    $ONE_ROW, 'unique race does not insert a second approval action' );

my $erasure_pk_requests =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$erasure_pk_requests->create(
    {
        deletion_request_id => 'request-pk',
        reason              => 'user requested account deletion',
        request_type        => 'anonymize',
        requester_user_id   => 'user-pk',
        resource_id         => 'user-pk',
        resource_type       => 'user',
        status              => 'pending',
    }
);
my $erasure_pk_jobs =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$erasure_pk_jobs->create(
    {
        deletion_request_id => 'other-request',
        erasure_job_id      => 'generated-1',
        status              => 'pending',
    }
);
my $erasure_pk_actions = GPForum::Test::ModerationResultSet->new;
my $erasure_pk_holds =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $erasure_pk_events = GPForum::Test::ModerationResultSet->new;
my $erasure_pk_outbox = GPForum::Test::ModerationResultSet->new;
my $erasure_pk_audits = GPForum::Test::ModerationResultSet->new;
my $erasure_pk_store  = GPForum::Service::Privacy::DeletionWorkflow->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog        => $erasure_pk_audits,
            DeletionAction  => $erasure_pk_actions,
            DeletionRequest => $erasure_pk_requests,
            ErasureJob      => $erasure_pk_jobs,
            EventLog        => $erasure_pk_events,
            OutboxMessage   => $erasure_pk_outbox,
            RetentionHold   => $erasure_pk_holds,
        },
    ),
);
my $erasure_pk =
  $erasure_pk_store->approve_request( 'request-pk', 'admin-1',
    'verified account owner request' );
ok( $erasure_pk->{ok}, 'unique erasure id collision remints and approves' );
ok( !$erasure_pk->{idempotent},
    'unique erasure id collision does not replay another job' );
is( $erasure_pk->{job}{erasure_job_id},
    'generated-2', 'unique erasure id collision remints the id' );
is( $erasure_pk->{request_id},
    'request-pk', 'unique erasure id collision keeps this request' );
is( scalar @{ $erasure_pk_jobs->created },
    $TWO_ROWS, 'unique erasure id collision inserts this job' );

my $erasure_leftover_requests =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$erasure_leftover_requests->create(
    {
        deletion_request_id => 'request-leftover',
        reason              => 'user requested account deletion',
        request_type        => 'anonymize',
        requester_user_id   => 'user-leftover',
        resource_id         => 'user-leftover',
        resource_type       => 'user',
        status              => 'pending',
    }
);
my $erasure_leftover_jobs =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$erasure_leftover_jobs->create(
    {
        deletion_request_id => 'request-leftover',
        erasure_job_id      => 'generated-1',
        status              => 'pending',
    }
);
$erasure_leftover_jobs->skip_search(1);
my $erasure_leftover_actions =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $erasure_leftover_holds =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $erasure_leftover_events = GPForum::Test::ModerationResultSet->new;
my $erasure_leftover_outbox = GPForum::Test::ModerationResultSet->new;
my $erasure_leftover_audits = GPForum::Test::ModerationResultSet->new;
my $erasure_leftover_store  = GPForum::Service::Privacy::DeletionWorkflow->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog        => $erasure_leftover_audits,
            DeletionAction  => $erasure_leftover_actions,
            DeletionRequest => $erasure_leftover_requests,
            ErasureJob      => $erasure_leftover_jobs,
            EventLog        => $erasure_leftover_events,
            OutboxMessage   => $erasure_leftover_outbox,
            RetentionHold   => $erasure_leftover_holds,
        },
    ),
);
my $erasure_leftover =
  $erasure_leftover_store->approve_request( 'request-leftover', 'admin-1',
    'verified account owner request' );
ok( $erasure_leftover->{ok},
    'leftover erasure id race reuses this job and finishes approval' );
ok( !$erasure_leftover->{idempotent},
    'leftover erasure id race does not skip the missing action' );
is( $erasure_leftover->{job}{erasure_job_id},
    'generated-1', 'leftover erasure id race keeps this job' );
is( $erasure_leftover->{request_id},
    'request-leftover', 'leftover erasure id race keeps this request' );
is( scalar @{ $erasure_leftover_jobs->created },
    $ONE_ROW, 'leftover erasure id race does not insert a second job' );
is( scalar @{ $erasure_leftover_actions->created },
    $ONE_ROW, 'leftover erasure id race inserts the missing approval action' );

my $action_pk_requests =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$action_pk_requests->create(
    {
        deletion_request_id => 'request-pk',
        reason              => 'user requested account deletion',
        request_type        => 'anonymize',
        requester_user_id   => 'user-pk',
        resource_id         => 'user-pk',
        resource_type       => 'user',
        status              => 'pending',
    }
);
my $action_pk_actions = GPForum::Test::ModerationResultSet->new;
$action_pk_actions->create(
    {
        action_type         => 'held',
        actor_id            => 'other-admin',
        deletion_action_id  => 'generated-1',
        deletion_request_id => 'other-request',
    }
);
my $action_pk_events = GPForum::Test::ModerationResultSet->new;
my $action_pk_outbox = GPForum::Test::ModerationResultSet->new;
my $action_pk_audits = GPForum::Test::ModerationResultSet->new;
my $action_pk_store  = GPForum::Service::Privacy::DeletionWorkflow->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog        => $action_pk_audits,
            DeletionAction  => $action_pk_actions,
            DeletionRequest => $action_pk_requests,
            EventLog        => $action_pk_events,
            OutboxMessage   => $action_pk_outbox,
        },
    ),
);
my $action_pk =
  $action_pk_store->hold_request( 'request-pk', 'admin-1', 'legal hold',
    { retention_hold_id => 'hold-pk' },
  );
ok( $action_pk->{ok}, 'unique deletion action id collision remints and holds' );
is( $action_pk->{action}{deletion_action_id},
    'generated-2', 'unique deletion action id collision remints the id' );
is( $action_pk->{action}{deletion_request_id},
    'request-pk', 'unique deletion action id collision keeps this request' );
is( scalar @{ $action_pk_actions->created },
    $TWO_ROWS, 'unique deletion action id collision inserts this action' );

my $completed = $workflow->complete_job( 'generated-7', 'worker-1' );
is( $completed->{erasure_job_id}, 'generated-7', 'completion returns job id' );
is( $completed->{action}{deletion_action_id},
    'generated-14', 'completion action id is generated' );
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

my $completed_request = $deletion_requests->find('generated-1');
my $completed_writes  = scalar @{ $completed_request->updates };
my $completed_again   = $workflow->complete_job( 'generated-7', 'worker-1' );
ok( $completed_again->{idempotent}, 'completed erasure job is idempotent' );
is( scalar @{ $deletion_actions->created },
    $TWO_ROWS, 'idempotent completion avoids duplicate actions' );
is( scalar @{ $completed_request->updates },
    $completed_writes, 'already-completed deletion request is not restamped' );
is( $completed_request->get_column('completed_at'),
    '2026-05-23T12:00:00Z',
    'already-completed deletion request keeps the original timestamp' );

$completed_request->update(
    {
        completed_at => undef,
        status       => 'approved',
    }
);
my $incomplete_complete = $workflow->complete_job( 'generated-7', 'worker-1' );
ok( $incomplete_complete->{idempotent},
    'incomplete request completion retry stays idempotent' );
is( $completed_request->get_column('status'),
    'completed',
    'incomplete request completion retry restores completed status' );
is( $completed_request->get_column('completed_at'),
    '2026-05-23T12:00:00Z',
    'incomplete request completion retry uses the job completed timestamp' );
is( scalar @{ $deletion_actions->created },
    $TWO_ROWS,
    'incomplete request completion retry avoids a second complete action' );

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

my $hold_again = $holds->create_hold(
    {
        resource_type => 'user',
        resource_id   => $HELD_USER_ID,
        reason        => 'legal investigation retry',
        created_by    => 'admin-2',
    }
);
is( $hold_again->{retention_hold_id},
    'generated-1', 'retry reuses the active retention hold' );
is( scalar @{ $retention_holds->created },
    $ONE_ROW, 'retry does not insert a second retention hold' );

$retention_holds->skip_search(1);
my $raced_hold = $holds->create_hold(
    {
        resource_type => 'user',
        resource_id   => $HELD_USER_ID,
        reason        => 'concurrent hold after lookup miss',
        created_by    => 'admin-2',
    }
);
is( $raced_hold->{retention_hold_id},
    'generated-1', 'unique race reuses the active retention hold' );
is( scalar @{ $retention_holds->created },
    $ONE_ROW, 'unique race does not insert a second retention hold' );

my $hold_pk_rows =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$hold_pk_rows->create(
    {
        created_by        => 'other-admin',
        ends_at           => undef,
        reason            => 'other',
        resource_id       => 'other-user',
        resource_type     => 'user',
        retention_hold_id => 'generated-1',
    }
);
my $hold_pk_events = GPForum::Test::ModerationResultSet->new;
my $hold_pk_outbox = GPForum::Test::ModerationResultSet->new;
my $hold_pk_audits = GPForum::Test::ModerationResultSet->new;
my $hold_pk_store  = GPForum::Service::Privacy::RetentionHoldStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog      => $hold_pk_audits,
            EventLog      => $hold_pk_events,
            OutboxMessage => $hold_pk_outbox,
            RetentionHold => $hold_pk_rows,
        },
    ),
);
my $hold_pk = $hold_pk_store->create_hold(
    {
        created_by    => 'admin-2',
        reason        => 'legal investigation',
        resource_id   => 'user-pk',
        resource_type => 'user',
    }
);
is( $hold_pk->{retention_hold_id},
    'generated-2', 'unique hold id collision remints the id' );
is( $hold_pk->{resource_id},
    'user-pk', 'unique hold id collision keeps this resource' );
is( scalar @{ $hold_pk_rows->created },
    $TWO_ROWS, 'unique hold id collision inserts this hold' );
is( scalar @{ $hold_pk_events->created },
    $ONE_ROW, 'unique hold id collision records this created event' );

my $hold_leftover_rows =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$hold_leftover_rows->create(
    {
        created_by        => 'admin-2',
        ends_at           => undef,
        reason            => 'legal investigation',
        resource_id       => 'user-leftover',
        resource_type     => 'user',
        retention_hold_id => 'generated-1',
    }
);
$hold_leftover_rows->skip_search(1);
my $hold_leftover_events = GPForum::Test::ModerationResultSet->new;
my $hold_leftover_outbox = GPForum::Test::ModerationResultSet->new;
my $hold_leftover_audits = GPForum::Test::ModerationResultSet->new;
my $hold_leftover_store  = GPForum::Service::Privacy::RetentionHoldStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog      => $hold_leftover_audits,
            EventLog      => $hold_leftover_events,
            OutboxMessage => $hold_leftover_outbox,
            RetentionHold => $hold_leftover_rows,
        },
    ),
);
my $hold_leftover = $hold_leftover_store->create_hold(
    {
        created_by    => 'admin-2',
        reason        => 'legal investigation',
        resource_id   => 'user-leftover',
        resource_type => 'user',
    }
);
is( $hold_leftover->{retention_hold_id},
    'generated-1', 'leftover hold id race keeps this hold' );
is( $hold_leftover->{resource_id},
    'user-leftover', 'leftover hold id race keeps this resource' );
is( scalar @{ $hold_leftover_rows->created },
    $ONE_ROW, 'leftover hold id race does not insert a second hold' );
is( scalar @{ $hold_leftover_events->created },
    $ONE_ROW, 'leftover hold id race inserts the missing event' );
is( scalar @{ $hold_leftover_outbox->created },
    $ONE_ROW, 'leftover hold id race inserts the missing outbox' );
is( scalar @{ $hold_leftover_audits->created },
    $ONE_ROW, 'leftover hold id race inserts the missing audit' );

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

my $blocked_actions = scalar @{ $deletion_actions->created };
my $blocked_events  = scalar @{ $event_log->created };
my $blocked_again =
  $workflow->complete_job( $job_hold_approval->{job}{erasure_job_id},
    'worker-2', );
ok( $blocked_again->{idempotent}, 'blocked erasure job retry is idempotent' );
ok( !$blocked_again->{ok},        'blocked erasure job retry stays blocked' );
is( $blocked_again->{error},
    'retention_hold_active', 'blocked erasure job retry reports hold error' );
is( scalar @{ $deletion_actions->created },
    $blocked_actions, 'blocked erasure job retry avoids duplicate actions' );
is( scalar @{ $event_log->created },
    $blocked_events, 'blocked erasure job retry avoids duplicate events' );

my $held_request =
  $deletion_requests->find( $job_hold_request->{deletion_request_id} );
my $held_job =
  $erasure_jobs->find( $job_hold_approval->{job}{erasure_job_id} );
my $held_writes = scalar @{ $held_request->updates };
$held_job->update( { last_error => undef } );
my $incomplete_error =
  $workflow->complete_job( $job_hold_approval->{job}{erasure_job_id},
    'worker-2', );
ok( !$incomplete_error->{ok}, 'incomplete last_error retry stays blocked' );
is(
    $held_job->get_column('last_error'),
    'retention hold active',
    'incomplete last_error retry restores the job error'
);
is( scalar @{ $held_request->updates },
    $held_writes, 'already-held deletion request is not restamped' );
is( scalar @{ $deletion_actions->created },
    $blocked_actions,
    'incomplete last_error retry avoids a second hold action' );
is( scalar @{ $event_log->created },
    $blocked_events, 'incomplete last_error retry avoids a second hold event' );

$held_request->update( { status => 'approved' } );
my $held_job_writes = scalar @{ $held_job->updates };
my $incomplete_hold =
  $workflow->complete_job( $job_hold_approval->{job}{erasure_job_id},
    'worker-2', );
ok( !$incomplete_hold->{ok}, 'incomplete held-status retry stays blocked' );
is( $held_request->get_column('status'),
    'held', 'incomplete held-status retry restores held' );
is( scalar @{ $held_job->updates },
    $held_job_writes, 'already-blocked job error is not restamped' );
is( scalar @{ $deletion_actions->created },
    $blocked_actions,
    'incomplete held-status retry avoids a second hold action' );
is( scalar @{ $event_log->created },
    $blocked_events,
    'incomplete held-status retry avoids a second hold event' );

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
