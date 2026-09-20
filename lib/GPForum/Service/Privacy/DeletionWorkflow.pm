package GPForum::Service::Privacy::DeletionWorkflow;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Privacy::Completion;
use GPForum::Service::Privacy::Erasure;
use GPForum::Service::Privacy::Event;
use GPForum::Service::Privacy::Record;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $STATUS_PENDING         => 'pending';
const my $STATUS_APPROVED        => 'approved';
const my $STATUS_COMPLETED       => 'completed';
const my $STATUS_HELD            => 'held';
const my $JOB_PENDING            => 'pending';
const my $JOB_DONE               => 'done';
const my $LEGAL_HOLD             => 'legal hold';
const my $DELETION_ID_CONSTRAINT => 'deletion_requests_pkey';
const my $OPEN_DELETION_CONSTRAINT =>
  'idx_deletion_requests_open_resource_unique';
const my $ERASURE_ID_CONSTRAINT      => 'erasure_jobs_pkey';
const my $ERASURE_REQUEST_CONSTRAINT => 'idx_erasure_jobs_request_unique';
const my $ACTION_ID_CONSTRAINT       => 'deletion_actions_pkey';
const my $ROW_LIMIT_ONE              => 1;

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema     => undef;
has record     => sub { return GPForum::Service::Privacy::Record->new; };
has completion => sub {
    my ($self) = @_;

    return GPForum::Service::Privacy::Completion->new( record => $self->record,
    );
};
has erasure => sub {
    my ($self) = @_;

    return GPForum::Service::Privacy::Erasure->new( record => $self->record );
};
has events => sub {
    my ($self) = @_;

    return GPForum::Service::Privacy::Event->new( record => $self->record );
};

sub request_deletion {
    my ( $self, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            return $self->_create_or_reuse_deletion($input);
        }
    );
}

sub approve_request {
    my ( $self, $request_id, $actor_id, $reason ) = @_;

    return $self->schema->txn_do(
        sub {
            return $self->_approve_in_txn(
                {
                    actor_id   => $actor_id,
                    reason     => $reason,
                    request_id => $request_id,
                }
            );
        }
    );
}

sub complete_job {
    my ( $self, $erasure_job_id, $actor_id ) = @_;

    return $self->schema->txn_do(
        sub {
            return $self->_complete_in_txn(
                {
                    actor_id       => $actor_id,
                    erasure_job_id => $erasure_job_id,
                }
            );
        }
    );
}

sub hold_request {
    my ( $self, $request_id, $actor_id, $reason, $hold ) = @_;

    return $self->schema->txn_do(
        sub {
            return $self->_hold_in_txn(
                {
                    actor_id   => $actor_id,
                    hold       => $hold,
                    reason     => $reason,
                    request_id => $request_id,
                }
            );
        }
    );
}

sub _create_or_reuse_deletion {
    my ( $self, $input ) = @_;

    $self->_lock_open_deletion($input);
    my $existing = $self->_open_deletion_hash($input);
    if ($existing) {
        return $self->_finish_leftover_deletion($existing);
    }

    return $self->_insert_or_reuse_deletion($input);
}

sub _insert_or_reuse_deletion {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_deletion_request($input); };
    if ($created) {
        return $created;
    }

    return $self->_reuse_after_conflict( $input, $EVAL_ERROR );
}

sub _reuse_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_deletion_after_unique( $input, $error );
}

sub _deletion_after_unique {
    my ( $self, $input, $error ) = @_;

    if ( _deletion_id_conflict($error) ) {
        return $self->_deletion_after_id_conflict($input);
    }
    if ( _open_deletion_conflict($error) ) {
        return $self->_reuse_deletion_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _deletion_after_id_conflict {
    my ( $self, $input ) = @_;

    my $existing = $self->_open_deletion_hash($input);
    if ($existing) {
        return $self->_finish_leftover_deletion($existing);
    }

    return $self->_retry_deletion_id($input);
}

sub _retry_deletion_id {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_create_deletion_request($input); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _reuse_deletion_row {
    my ( $self, $input, $error ) = @_;

    my $existing = $self->_open_deletion_hash($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_finish_leftover_deletion($existing);
}

sub _deletion_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $DELETION_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _open_deletion_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $OPEN_DELETION_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _create_deletion_request {
    my ( $self, $input ) = @_;

    my $request = {
        completed_at        => undef,
        created_at          => $self->clock->now_iso8601,
        deletion_request_id => $self->id_service->uuid,
        reason              => $input->{reason} || q{},
        request_type        => $input->{request_type},
        requester_user_id   => $input->{requester_user_id},
        resource_id         => $input->{resource_id},
        resource_type       => $input->{resource_type},
        status              => $STATUS_PENDING,
    };
    $self->schema->resultset('DeletionRequest')->create($request);
    $self->_record_privacy_event_and_audit(
        $self->events->requested(
            {
                actor_id => $input->{requester_user_id},
                request  => $request,
            }
        )
    );

    return $request;
}

sub _finish_leftover_deletion {
    my ( $self, $existing ) = @_;

    $self->_ensure_deletion_write($existing);

    return $existing;
}

sub _ensure_deletion_write {
    my ( $self, $existing ) = @_;

    if ( $self->_deletion_event_exists($existing) ) {
        return;
    }

    return $self->_record_privacy_event_and_audit(
        $self->events->requested(
            {
                actor_id => $existing->{requester_user_id},
                request  => $existing,
            }
        )
    );
}

sub _deletion_event_exists {
    my ( $self, $existing ) = @_;

    my $search = $self->schema->resultset('EventLog')->search(
        {
            idempotency_key => join( q{:},
                'privacy.deletion_requested',
                $existing->{deletion_request_id} ),
        },
        { rows => $ROW_LIMIT_ONE },
    );

    if ( $search->can('single') ) {
        return $search->single;
    }

    return;
}

sub _approve_in_txn {
    my ( $self, $input ) = @_;

    $self->_lock_deletion_request_for_approval( $input->{request_id} );
    my $request =
      $self->schema->resultset('DeletionRequest')->find( $input->{request_id} );
    if ( !$request ) {
        return;
    }

    $input->{request}   = $request;
    $input->{timestamp} = $self->clock->now_iso8601;
    return $self->_approved_or_held($input);
}

sub _approved_or_held {
    my ( $self, $input ) = @_;

    my $existing = $self->_existing_job_for( $input->{request_id} );
    if ($existing) {
        return $self->_finish_leftover_approval( $input, $existing );
    }

    return $self->_hold_or_create($input);
}

sub _hold_or_create {
    my ( $self, $input ) = @_;

    my $hold = $self->_active_hold_for_request( $input->{request} );
    if ($hold) {
        return $self->_hold_request(
            {
                actor_id  => $input->{actor_id},
                hold      => $hold,
                reason    => $self->completion->hold_reason( $input->{reason} ),
                request   => $input->{request},
                timestamp => $input->{timestamp},
            }
        );
    }

    return $self->_create_approval($input);
}

sub _create_approval {
    my ( $self, $input ) = @_;

    $self->_set_request_status( $input->{request}, $STATUS_APPROVED );
    my $inserted = $self->_insert_or_reuse_job($input);
    if ( $inserted->{reused} ) {
        return $self->_finish_leftover_approval( $input, $inserted->{job} );
    }

    return $self->_emit_approval( $input, $inserted->{job} );
}

sub _finish_leftover_approval {
    my ( $self, $input, $job ) = @_;

    if ( $self->_existing_approval_action( $input->{request_id} ) ) {
        return $self->completion->approval_replay( $input->{request_id}, $job );
    }

    $self->_set_request_status( $input->{request}, $STATUS_APPROVED );
    return $self->_emit_approval( $input, $job );
}

sub _existing_approval_action {
    my ( $self, $request_id ) = @_;

    return $self->_latest_row(
        'DeletionAction',
        {
            action_type         => 'released',
            deletion_request_id => $request_id,
        },
        'created_at',
    );
}

sub _emit_approval {
    my ( $self, $input, $job ) = @_;

    my $action = $self->_approval_action($input);
    $self->_record_privacy_event_and_audit(
        $self->events->approved(
            {
                %{$input},
                action => $action,
                job    => $job,
            }
        )
    );

    return {
        action     => $action,
        job        => $self->record->job_hash($job),
        ok         => 1,
        request_id => $input->{request_id},
    };
}

sub _approval_action {
    my ( $self, $input ) = @_;

    return $self->_record_action(
        $input->{request_id},
        {
            action_type => 'released',
            actor_id    => $input->{actor_id},
            created_at  => $input->{timestamp},
            metadata    => {
                reason => $input->{reason} || q{},
                status => $STATUS_APPROVED,
            },
        }
    );
}

sub _create_erasure_job {
    my ( $self, $input ) = @_;

    my $job = {
        completed_at        => undef,
        deletion_request_id => $input->{request_id},
        erasure_job_id      => $self->id_service->uuid,
        last_error          => undef,
        scheduled_at        => $input->{timestamp},
        status              => $JOB_PENDING,
    };
    $self->schema->resultset('ErasureJob')->create($job);

    return $job;
}

sub _insert_or_reuse_job {
    my ( $self, $input ) = @_;

    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_erasure_job($input); },
      );
    if ($created) {
        return { job => $created, reused => 0 };
    }

    return $self->_job_after_conflict( $input, $error );
}

sub _job_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_job_after_unique( $input, $error );
}

sub _job_after_unique {
    my ( $self, $input, $error ) = @_;

    if ( _erasure_id_conflict($error) ) {
        return $self->_job_after_id_conflict($input);
    }
    if ( _erasure_request_conflict($error) ) {
        return $self->_reuse_erasure_job( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _job_after_id_conflict {
    my ( $self, $input ) = @_;

    my $existing = $self->_existing_job_for( $input->{request_id} );
    if ($existing) {
        return { job => $existing, reused => 1 };
    }

    return $self->_retry_erasure_id($input);
}

sub _retry_erasure_id {
    my ( $self, $input ) = @_;

    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_erasure_job($input); },
      );
    if ($created) {
        return { job => $created, reused => 0 };
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _reuse_erasure_job {
    my ( $self, $input, $error ) = @_;

    my $existing = $self->_existing_job_for( $input->{request_id} );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return { job => $existing, reused => 1 };
}

sub _erasure_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ERASURE_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _erasure_request_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ERASURE_REQUEST_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _complete_in_txn {
    my ( $self, $input ) = @_;

    my $job =
      $self->schema->resultset('ErasureJob')->find( $input->{erasure_job_id} );
    if ( !$job ) {
        return;
    }
    if ( $self->completion->job_done($job) ) {
        return $self->_already_completed( $input, $job );
    }

    return $self->_complete_with_request( $input, $job );
}

sub _already_completed {
    my ( $self, $input, $job ) = @_;

    $self->_finish_completed_request($job);

    return $self->completion->completion_replay( $input->{erasure_job_id} );
}

sub _finish_completed_request {
    my ( $self, $job ) = @_;

    my $request_id = $self->record->column( $job, 'deletion_request_id' );
    my $request =
      $self->schema->resultset('DeletionRequest')->find($request_id);
    if ( !$request ) {
        return;
    }

    $self->_complete_request_row( $request, $self->_job_completed_at($job) );

    return;
}

sub _job_completed_at {
    my ( $self, $job ) = @_;

    my $completed_at = $self->record->column( $job, 'completed_at' );
    if ( defined $completed_at && length $completed_at ) {
        return $completed_at;
    }

    return $self->clock->now_iso8601;
}

sub _complete_with_request {
    my ( $self, $input, $job ) = @_;

    my $request_id = $job->get_column('deletion_request_id');
    my $request =
      $self->schema->resultset('DeletionRequest')->find($request_id);
    if ( !$request ) {
        return;
    }

    $input->{job}       = $job;
    $input->{request}   = $request;
    $input->{timestamp} = $self->clock->now_iso8601;
    return $self->_erase_or_block($input);
}

sub _erase_or_block {
    my ( $self, $input ) = @_;

    my $hold = $self->_active_hold_for_request( $input->{request} );
    if ($hold) {
        $input->{hold} = $hold;
        return $self->_block_or_replay($input);
    }

    return $self->_finish_erasure($input);
}

sub _block_or_replay {
    my ( $self, $input ) = @_;

    if ( $self->_already_blocked($input) ) {
        return $self->completion->hold_block_replay( $input->{erasure_job_id} );
    }

    return $self->_block_erasure($input);
}

sub _already_blocked {
    my ( $self, $input ) = @_;

    if ( !$self->_already_held( $input->{request} ) ) {
        return;
    }

    return $self->_job_has_block_error( $input->{job} );
}

sub _block_erasure {
    my ( $self, $input ) = @_;

    my $held    = $self->_already_held( $input->{request} );
    my $blocked = $self->_job_has_block_error( $input->{job} );
    $self->_set_request_status( $input->{request}, $STATUS_HELD );
    $self->_set_block_error( $input->{job} );
    if ( $held || $blocked ) {
        return $self->_blocked_result($input);
    }

    return $self->_emit_block($input);
}

sub _emit_block {
    my ( $self, $input ) = @_;

    my $action = $self->_block_action($input);
    $self->_record_privacy_event_and_audit(
        $self->events->blocked( { %{$input}, action => $action } ) );

    return $self->_blocked_result( $input, $action );
}

sub _blocked_result {
    my ( $self, $input, $action ) = @_;

    return {
        action         => $action,
        erasure_job_id => $input->{erasure_job_id},
        error          => 'retention_hold_active',
        ok             => 0,
    };
}

sub _block_action {
    my ( $self, $input ) = @_;

    return $self->_record_action(
        $self->record->column( $input->{request}, 'deletion_request_id' ),
        {
            action_type => 'held',
            actor_id    => $input->{actor_id},
            created_at  => $input->{timestamp},
            metadata    => {
                erasure_job_id    => $input->{erasure_job_id},
                retention_hold_id =>
                  $self->record->column( $input->{hold}, 'retention_hold_id' ),
            },
        }
    );
}

sub _finish_erasure {
    my ( $self, $input ) = @_;

    my $anonymized =
      $self->_anonymize_request_subject( $input->{request},
        $input->{timestamp} );
    $input->{job}->update(
        {
            completed_at => $input->{timestamp},
            status       => $JOB_DONE,
        }
    );
    $self->_complete_request_row( $input->{request}, $input->{timestamp} );

    return $self->_completed_result( $input, $anonymized );
}

sub _completed_result {
    my ( $self, $input, $anonymized ) = @_;

    my $action = $self->_complete_action( $input, $anonymized );
    $self->_record_privacy_event_and_audit(
        $self->events->completed(
            {
                %{$input},
                action     => $action,
                anonymized => $anonymized,
            }
        )
    );

    return {
        action         => $action,
        anonymized     => $anonymized,
        erasure_job_id => $input->{erasure_job_id},
        ok             => 1,
    };
}

sub _complete_action {
    my ( $self, $input, $anonymized ) = @_;

    return $self->_record_action(
        $self->record->column( $input->{request}, 'deletion_request_id' ),
        {
            action_type => 'anonymized',
            actor_id    => $input->{actor_id},
            created_at  => $input->{timestamp},
            metadata    => {
                anonymized     => $anonymized,
                erasure_job_id => $input->{erasure_job_id},
            },
        }
    );
}

sub _hold_in_txn {
    my ( $self, $input ) = @_;

    my $request =
      $self->schema->resultset('DeletionRequest')->find( $input->{request_id} );
    if ( !$request ) {
        return;
    }

    my $held = $self->_hold_request(
        {
            actor_id  => $input->{actor_id},
            hold      => $input->{hold},
            reason    => $input->{reason} || $LEGAL_HOLD,
            request   => $request,
            timestamp => $self->clock->now_iso8601,
        }
    );

    return { %{$held}, error => undef, ok => 1 };
}

sub _lock_deletion_request_for_approval {
    my ( $self, $request_id ) = @_;

    my $dbh = $self->_schema_dbh;
    if ( !$dbh ) {
        return;
    }

    $dbh->selectrow_array(
'SELECT deletion_request_id FROM deletion_requests WHERE deletion_request_id = ? FOR UPDATE',
        undef, $request_id
    );

    return;
}

sub _lock_open_deletion {
    my ( $self, $input ) = @_;

    my $dbh = $self->_schema_dbh;
    if ( !$dbh ) {
        return;
    }

    $dbh->selectrow_array(
'SELECT deletion_request_id FROM deletion_requests WHERE resource_type = ? AND resource_id = ? AND request_type = ? AND status IN (?, ?, ?) FOR UPDATE',
        undef,
        $input->{resource_type},
        $input->{resource_id},
        $input->{request_type},
        $STATUS_PENDING,
        $STATUS_APPROVED,
        $STATUS_HELD,
    );

    return;
}

sub _open_deletion_hash {
    my ( $self, $input ) = @_;

    my $row = $self->_latest_row( 'DeletionRequest',
        $self->_open_deletion_query($input), 'created_at', );
    if ( !$row ) {
        return;
    }

    return $self->record->request_hash($row);
}

sub _open_deletion_query {
    my ( undef, $input ) = @_;

    return {
        request_type  => $input->{request_type},
        resource_id   => $input->{resource_id},
        resource_type => $input->{resource_type},
        status        => {
            -in => [ $STATUS_PENDING, $STATUS_APPROVED, $STATUS_HELD ],
        },
    };
}

sub _record_action {
    my ( $self, $request_id, $input ) = @_;

    my $created =
      eval { return $self->_insert_deletion_action( $request_id, $input ); };
    if ($created) {
        return $created;
    }

    return $self->_deletion_action_after_conflict( $request_id, $input,
        $EVAL_ERROR );
}

sub _insert_deletion_action {
    my ( $self, $request_id, $input ) = @_;

    my $action = {
        action_type         => $input->{action_type},
        actor_id            => $input->{actor_id},
        created_at          => $input->{created_at},
        deletion_action_id  => $self->id_service->uuid,
        deletion_request_id => $request_id,
        metadata            => $input->{metadata} || {},
    };
    $self->schema->resultset('DeletionAction')->create($action);

    return $action;
}

sub _deletion_action_after_conflict {
    my ( $self, $request_id, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_deletion_action_id_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_deletion_action_id( $request_id, $input );
}

sub _retry_deletion_action_id {
    my ( $self, $request_id, $input ) = @_;

    my $created =
      eval { return $self->_insert_deletion_action( $request_id, $input ); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _deletion_action_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ACTION_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _hold_request {
    my ( $self, $input ) = @_;

    if ( $self->_already_held( $input->{request} ) ) {
        return $self->_held_snapshot($input);
    }

    return $self->_apply_hold($input);
}

sub _already_held {
    my ( $self, $request ) = @_;

    return $self->_same_request_status( $request, $STATUS_HELD );
}

sub _same_request_status {
    my ( $self, $request, $status ) = @_;

    my $held = $self->record->column( $request, 'status' ) || q{};
    if ( $held eq $status ) {
        return 1;
    }

    return 0;
}

sub _set_request_status {
    my ( $self, $request, $status ) = @_;

    if ( $self->_same_request_status( $request, $status ) ) {
        return;
    }

    $request->update( { status => $status } );

    return;
}

sub _job_has_block_error {
    my ( $self, $job ) = @_;

    my $error = $self->record->column( $job, 'last_error' ) || q{};
    if ( $error eq $self->events->block_error ) {
        return 1;
    }

    return 0;
}

sub _set_block_error {
    my ( $self, $job ) = @_;

    if ( $self->_job_has_block_error($job) ) {
        return;
    }

    $job->update( { last_error => $self->events->block_error } );

    return;
}

sub _complete_request_row {
    my ( $self, $request, $timestamp ) = @_;

    if ( $self->_same_request_status( $request, $STATUS_COMPLETED ) ) {
        return;
    }

    $request->update(
        {
            completed_at => $timestamp,
            status       => $STATUS_COMPLETED,
        }
    );

    return;
}

sub _held_snapshot {
    my ( $self, $input ) = @_;

    my $request_id =
      $self->record->column( $input->{request}, 'deletion_request_id' );

    return {
        action     => undef,
        error      => 'retention_hold_active',
        ok         => 0,
        request_id => $request_id,
    };
}

sub _apply_hold {
    my ( $self, $input ) = @_;

    my $request    = $input->{request};
    my $request_id = $self->record->column( $request, 'deletion_request_id' );
    $self->_set_request_status( $request, $STATUS_HELD );
    my $action = $self->_hold_action( $input, $request_id );
    $self->_record_privacy_event_and_audit( $self->events->held($input) );

    return {
        action     => $action,
        error      => 'retention_hold_active',
        ok         => 0,
        request_id => $request_id,
    };
}

sub _hold_action {
    my ( $self, $input, $request_id ) = @_;

    return $self->_record_action(
        $request_id,
        {
            action_type => 'held',
            actor_id    => $input->{actor_id},
            created_at  => $input->{timestamp},
            metadata    => {
                reason            => $input->{reason},
                retention_hold_id =>
                  $self->record->column( $input->{hold}, 'retention_hold_id' ),
            },
        }
    );
}

sub _existing_job_for {
    my ( $self, $request_id ) = @_;

    return $self->_latest_row( 'ErasureJob',
        { deletion_request_id => $request_id },
        'scheduled_at', );
}

sub _active_hold_for_request {
    my ( $self, $request ) = @_;

    return $self->_latest_row(
        'RetentionHold',
        {
            ends_at       => undef,
            resource_id   => $self->record->column( $request, 'resource_id' ),
            resource_type => $self->record->column( $request, 'resource_type' ),
        },
        'created_at',
    );
}

sub _latest_row {
    my ( $self, $resultset_name, $query, $order_field ) = @_;

    my $search = $self->schema->resultset($resultset_name)->search(
        $query,
        {
            order_by => [ { -desc => $order_field } ],
            rows     => 1,
        }
    );
    if ( $search->can('single') ) {
        return $search->single;
    }

    my @rows = $self->record->rows($search);
    return $rows[0];
}

sub _anonymize_request_subject {
    my ( $self, $request, $timestamp ) = @_;

    my $user = $self->_erasure_user($request);
    my $skip = $self->erasure->skip_reason( $request, $user );
    if ($skip) {
        return $self->completion->skipped($skip);
    }

    return $self->_erase_user( $user,
        $self->record->column( $request, 'resource_id' ), $timestamp );
}

sub _erasure_user {
    my ( $self, $request ) = @_;

    if ( !$self->erasure->is_user_resource($request) ) {
        return;
    }

    return $self->schema->resultset('User')
      ->find( $self->record->column( $request, 'resource_id' ) );
}

sub _erase_user {
    my ( $self, $user, $user_id, $timestamp ) = @_;

    my $already = $self->erasure->already_deleted($user);
    if ( !$already ) {
        $user->update( $self->erasure->user_values( $user_id, $timestamp ) );
    }
    $self->_revoke_user_rows( 'Credential', $user_id, $timestamp );
    $self->_revoke_user_rows( 'Session',    $user_id, $timestamp );

    return $self->erasure->result( $user_id, $already );
}

sub _revoke_user_rows {
    my ( $self, $resultset_name, $user_id, $timestamp ) = @_;

    my $resultset = eval { return $self->schema->resultset($resultset_name); };
    if ( !$resultset ) {
        return;
    }

    my $search = $resultset->search(
        {
            revoked_at => undef,
            user_id    => $user_id,
        }
    );
    $self->_revoke_rows( $search, $timestamp );

    return;
}

sub _revoke_rows {
    my ( $self, $search, $timestamp ) = @_;

    for my $row ( $self->record->rows($search) ) {
        $self->_revoke_row( $row, $timestamp );
    }

    return;
}

sub _revoke_row {
    my ( undef, $row, $timestamp ) = @_;

    if ( $row && $row->can('update') ) {
        $row->update( { revoked_at => $timestamp } );
    }

    return;
}

sub _record_privacy_event_and_audit {
    my ( $self, $input ) = @_;

    my $correlation_id = $self->id_service->uuid;
    $self->recorder->record_event(
        %{ $self->events->envelope( $input, $correlation_id ) } );
    $self->recorder->record_audit(
        %{ $self->events->audit( $input, $correlation_id ) } );

    return;
}

sub _schema_dbh {
    my ($self) = @_;

    my $storage = eval { return $self->schema->storage; };
    if ( !$storage || !$storage->can('dbh') ) {
        return;
    }

    my $dbh = eval { return $storage->dbh; };
    return $dbh;
}

1;
