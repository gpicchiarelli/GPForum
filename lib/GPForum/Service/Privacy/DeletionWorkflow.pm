package GPForum::Service::Privacy::DeletionWorkflow;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $STATUS_PENDING   => 'pending';
const my $STATUS_APPROVED  => 'approved';
const my $STATUS_COMPLETED => 'completed';
const my $STATUS_HELD      => 'held';
const my $JOB_PENDING      => 'pending';
const my $JOB_DONE         => 'done';
const my $SCHEMA_VERSION   => 1;
const my $USER_AGGREGATE   => 'user';
const my $DISPLAY_DELETED  => 'Deleted member';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has recorder   => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema => undef;

sub request_deletion {
    my ( $self, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            my $request = {
                deletion_request_id => $self->id_service->uuid,
                requester_user_id   => $input->{requester_user_id},
                resource_type       => $input->{resource_type},
                resource_id         => $input->{resource_id},
                request_type        => $input->{request_type},
                reason              => $input->{reason} || q{},
                status              => $STATUS_PENDING,
                created_at          => $self->clock->now_iso8601,
                completed_at        => undef,
            };
            $self->schema->resultset('DeletionRequest')->create($request);
            $self->_record_privacy_event_and_audit(
                {
                    action      => 'privacy.deletion_requested',
                    actor_id    => $input->{requester_user_id},
                    request     => $request,
                    payload     => _request_payload($request),
                    metadata    => { reason => $request->{reason} },
                    created_at  => $request->{created_at},
                    idempotency => $request->{deletion_request_id},
                }
            );

            return $request;
        }
    );
}

sub approve_request {
    my ( $self, $request_id, $actor_id, $reason ) = @_;

    return $self->schema->txn_do(
        sub {
            my $timestamp = $self->clock->now_iso8601;
            my $request =
              $self->schema->resultset('DeletionRequest')->find($request_id);
            return if !$request;

            my $existing_job = $self->_existing_job_for($request_id);
            return {
                ok         => 1,
                request_id => $request_id,
                job        => _job_hash($existing_job),
                idempotent => 1,
              }
              if $existing_job;

            my $hold = $self->_active_hold_for_request($request);
            return $self->_hold_request(
                {
                    actor_id   => $actor_id,
                    request    => $request,
                    reason     => $reason || 'active legal hold',
                    timestamp  => $timestamp,
                    hold       => $hold,
                    event_type => 'privacy.deletion_held',
                }
            ) if $hold;

            $request->update( { status => $STATUS_APPROVED } );

            my $action = $self->_record_action(
                $request_id,
                {
                    actor_id    => $actor_id,
                    action_type => 'released',
                    metadata    => {
                        status => $STATUS_APPROVED,
                        reason => $reason || q{},
                    },
                    created_at => $timestamp,
                }
            );
            my $job = {
                erasure_job_id      => $self->id_service->uuid,
                deletion_request_id => $request_id,
                status              => $JOB_PENDING,
                scheduled_at        => $timestamp,
                completed_at        => undef,
                last_error          => undef,
            };
            $self->schema->resultset('ErasureJob')->create($job);
            $self->_record_privacy_event_and_audit(
                {
                    action   => 'privacy.deletion_approved',
                    actor_id => $actor_id,
                    request  => $request,
                    payload  => {
                        %{ _request_payload($request) },
                        erasure_job_id => $job->{erasure_job_id},
                    },
                    metadata => {
                        deletion_action_id => $action->{deletion_action_id},
                        reason             => $reason || q{},
                    },
                    created_at  => $timestamp,
                    idempotency => $request_id . q{:approved},
                }
            );

            return {
                ok         => 1,
                request_id => $request_id,
                action     => $action,
                job        => $job,
            };
        }
    );
}

sub complete_job {
    my ( $self, $erasure_job_id, $actor_id ) = @_;

    return $self->schema->txn_do(
        sub {
            my $timestamp = $self->clock->now_iso8601;
            my $job =
              $self->schema->resultset('ErasureJob')->find($erasure_job_id);
            return if !$job;

            return {
                ok             => 1,
                erasure_job_id => $erasure_job_id,
                idempotent     => 1,
              }
              if ( _column( $job, 'status' ) || q{} ) eq $JOB_DONE;

            my $request_id = $job->get_column('deletion_request_id');
            my $request =
              $self->schema->resultset('DeletionRequest')->find($request_id);
            return if !$request;

            my $hold = $self->_active_hold_for_request($request);
            if ($hold) {
                $request->update( { status => $STATUS_HELD } );
                $job->update( { last_error => 'retention hold active' } );
                my $action = $self->_record_action(
                    $request_id,
                    {
                        actor_id    => $actor_id,
                        action_type => 'held',
                        metadata    => {
                            erasure_job_id    => $erasure_job_id,
                            retention_hold_id =>
                              _column( $hold, 'retention_hold_id' ),
                        },
                        created_at => $timestamp,
                    }
                );
                $self->_record_privacy_event_and_audit(
                    {
                        action   => 'privacy.erasure_blocked',
                        actor_id => $actor_id,
                        request  => $request,
                        payload  => {
                            %{ _request_payload($request) },
                            erasure_job_id => $erasure_job_id,
                        },
                        metadata => {
                            deletion_action_id => $action->{deletion_action_id},
                            reason             => 'retention hold active',
                        },
                        created_at  => $timestamp,
                        idempotency => $erasure_job_id . q{:blocked},
                    }
                );

                return {
                    ok             => 0,
                    error          => 'retention_hold_active',
                    erasure_job_id => $erasure_job_id,
                    action         => $action,
                };
            }

            my $anonymized =
              $self->_anonymize_request_subject( $request, $timestamp );
            $job->update( { status => $JOB_DONE, completed_at => $timestamp } );
            $request->update(
                {
                    status       => $STATUS_COMPLETED,
                    completed_at => $timestamp,
                }
            );

            my $action = $self->_record_action(
                $request_id,
                {
                    actor_id    => $actor_id,
                    action_type => 'anonymized',
                    metadata    => {
                        erasure_job_id => $erasure_job_id,
                        anonymized     => $anonymized,
                    },
                    created_at => $timestamp,
                }
            );
            $self->_record_privacy_event_and_audit(
                {
                    action   => 'privacy.erasure_completed',
                    actor_id => $actor_id,
                    request  => $request,
                    payload  => {
                        %{ _request_payload($request) },
                        erasure_job_id => $erasure_job_id,
                        anonymized     => $anonymized,
                    },
                    metadata => {
                        deletion_action_id => $action->{deletion_action_id},
                    },
                    created_at  => $timestamp,
                    idempotency => $erasure_job_id . q{:done},
                }
            );

            return {
                ok             => 1,
                erasure_job_id => $erasure_job_id,
                action         => $action,
                anonymized     => $anonymized,
            };
        }
    );
}

sub hold_request {
    my ( $self, $request_id, $actor_id, $reason, $hold ) = @_;

    return $self->schema->txn_do(
        sub {
            my $timestamp = $self->clock->now_iso8601;
            my $request =
              $self->schema->resultset('DeletionRequest')->find($request_id);
            return if !$request;

            my $held = $self->_hold_request(
                {
                    actor_id   => $actor_id,
                    event_type => 'privacy.deletion_held',
                    hold       => $hold,
                    reason     => $reason || 'legal hold',
                    request    => $request,
                    timestamp  => $timestamp,
                }
            );

            return { %{$held}, error => undef, ok => 1 };
        }
    );
}

sub _record_action {
    my ( $self, $request_id, $input ) = @_;

    my $action = {
        deletion_action_id  => $self->id_service->uuid,
        deletion_request_id => $request_id,
        actor_id            => $input->{actor_id},
        action_type         => $input->{action_type},
        metadata            => $input->{metadata} || {},
        created_at          => $input->{created_at},
    };
    $self->schema->resultset('DeletionAction')->create($action);

    return $action;
}

sub _hold_request {
    my ( $self, $input ) = @_;

    my $request    = $input->{request};
    my $request_id = _column( $request, 'deletion_request_id' );
    $request->update( { status => $STATUS_HELD } );
    my $action = $self->_record_action(
        $request_id,
        {
            actor_id    => $input->{actor_id},
            action_type => 'held',
            metadata    => {
                reason            => $input->{reason},
                retention_hold_id =>
                  _column( $input->{hold}, 'retention_hold_id' ),
            },
            created_at => $input->{timestamp},
        }
    );
    $self->_record_privacy_event_and_audit(
        {
            action      => $input->{event_type},
            actor_id    => $input->{actor_id},
            request     => $request,
            payload     => _request_payload($request),
            metadata    => { reason => $input->{reason} },
            created_at  => $input->{timestamp},
            idempotency => $request_id . q{:held},
        }
    );

    return {
        ok         => 0,
        error      => 'retention_hold_active',
        request_id => $request_id,
        action     => $action,
    };
}

sub _existing_job_for {
    my ( $self, $request_id ) = @_;

    my $search = $self->schema->resultset('ErasureJob')->search(
        { deletion_request_id => $request_id },
        {
            order_by => [ { -desc => 'scheduled_at' } ],
            rows     => 1,
        }
    );

    return $search->single if $search->can('single');

    my @rows = _rows($search);
    return $rows[0];
}

sub _active_hold_for_request {
    my ( $self, $request ) = @_;

    my $search = $self->schema->resultset('RetentionHold')->search(
        {
            resource_type => _column( $request, 'resource_type' ),
            resource_id   => _column( $request, 'resource_id' ),
            ends_at       => undef,
        },
        {
            order_by => [ { -desc => 'created_at' } ],
            rows     => 1,
        }
    );

    return $search->single if $search->can('single');

    my @rows = _rows($search);
    return $rows[0];
}

sub _anonymize_request_subject {
    my ( $self, $request, $timestamp ) = @_;

    return { skipped => 'resource_not_user' }
      if ( _column( $request, 'resource_type' ) || q{} ) ne $USER_AGGREGATE;

    my $user_id = _column( $request, 'resource_id' );
    my $user    = $self->schema->resultset('User')->find($user_id);
    return { skipped => 'user_not_found' } if !$user;

    my $already_deleted = defined _column( $user, 'deleted_at' );
    if ( !$already_deleted ) {
        $user->update(
            {
                username          => _anonymous_username($user_id),
                display_name      => $DISPLAY_DELETED,
                email_normalized  => _anonymous_email($user_id),
                password_hash     => 'erased',
                status            => 'deleted',
                trust_level       => 0,
                email_verified_at => undef,
                updated_at        => $timestamp,
                deleted_at        => $timestamp,
            }
        );
    }
    $self->_revoke_user_rows( 'Credential', $user_id, $timestamp );
    $self->_revoke_user_rows( 'Session',    $user_id, $timestamp );

    return { user_id => $user_id, idempotent => $already_deleted ? 1 : 0 };
}

sub _revoke_user_rows {
    my ( $self, $resultset_name, $user_id, $timestamp ) = @_;

    my $resultset = eval { $self->schema->resultset($resultset_name) };
    return if !$resultset;

    my $search = $resultset->search(
        {
            user_id    => $user_id,
            revoked_at => undef,
        }
    );

    for my $row ( _rows($search) ) {
        $row->update( { revoked_at => $timestamp } )
          if $row && $row->can('update');
    }

    return;
}

sub _record_privacy_event_and_audit {
    my ( $self, $input ) = @_;

    my $request        = $input->{request};
    my $correlation_id = $self->id_service->uuid;
    $self->recorder->record_event(
        event_type        => $input->{action},
        aggregate_type    => _column( $request, 'resource_type' ),
        aggregate_id      => _column( $request, 'resource_id' ),
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $input->{actor_id},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   =>
          join( q{:}, $input->{action}, $input->{idempotency} ),
        payload   => $input->{payload} || {},
        timestamp => $input->{created_at},
    );

    $self->recorder->record_audit(
        action         => $input->{action},
        schema_version => $SCHEMA_VERSION,
        actor_id       => $input->{actor_id},
        target_type    => _column( $request, 'resource_type' ),
        target_id      => _column( $request, 'resource_id' ),
        correlation_id => $correlation_id,
        previous_hash  => undef,
        record_hash    => q{},
        metadata       => {
            deletion_request_id => _column( $request, 'deletion_request_id' ),
            %{ $input->{metadata} || {} },
        },
        created_at => $input->{created_at},
    );

    return;
}

sub _request_payload {
    my ($request) = @_;

    return {
        deletion_request_id => _column( $request, 'deletion_request_id' ),
        resource_type       => _column( $request, 'resource_type' ),
        resource_id         => _column( $request, 'resource_id' ),
        request_type        => _column( $request, 'request_type' ),
        status              => _column( $request, 'status' ),
    };
}

sub _job_hash {
    my ($job) = @_;

    return if !$job;

    return {
        erasure_job_id      => _column( $job, 'erasure_job_id' ),
        deletion_request_id => _column( $job, 'deletion_request_id' ),
        status              => _column( $job, 'status' ),
        scheduled_at        => _column( $job, 'scheduled_at' ),
        completed_at        => _column( $job, 'completed_at' ),
        last_error          => _column( $job, 'last_error' ),
    };
}

sub _anonymous_username {
    my ($user_id) = @_;

    return 'deleted-' . _safe_identifier($user_id);
}

sub _anonymous_email {
    my ($user_id) = @_;

    return 'deleted+' . _safe_identifier($user_id) . '@example.invalid';
}

sub _safe_identifier {
    my ($value) = @_;

    $value =~ s/[^[:alnum:]]//gmsx;

    return lc $value;
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _column {
    my ( $row, $name ) = @_;

    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    return;
}

1;
