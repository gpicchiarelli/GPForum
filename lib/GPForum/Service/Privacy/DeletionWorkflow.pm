package GPForum::Service::Privacy::DeletionWorkflow;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $STATUS_PENDING   => 'pending';
const my $STATUS_APPROVED  => 'approved';
const my $STATUS_COMPLETED => 'completed';
const my $JOB_PENDING      => 'pending';
const my $JOB_DONE         => 'done';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub request_deletion {
    my ( $self, $input ) = @_;

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

    return $request;
}

sub approve_request {
    my ( $self, $request_id, $actor_id ) = @_;

    my $timestamp = $self->clock->now_iso8601;
    my $request =
      $self->schema->resultset('DeletionRequest')->find($request_id);
    $request->update( { status => $STATUS_APPROVED } );

    my $action = $self->_record_action(
        $request_id,
        {
            actor_id    => $actor_id,
            action_type => 'held',
            metadata    => { status => $STATUS_APPROVED },
            created_at  => $timestamp,
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

    return { request_id => $request_id, action => $action, job => $job };
}

sub complete_job {
    my ( $self, $erasure_job_id, $actor_id ) = @_;

    my $timestamp = $self->clock->now_iso8601;
    my $job = $self->schema->resultset('ErasureJob')->find($erasure_job_id);
    my $request_id = $job->get_column('deletion_request_id');

    $job->update( { status => $JOB_DONE, completed_at => $timestamp } );

    my $request =
      $self->schema->resultset('DeletionRequest')->find($request_id);
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
            metadata    => { erasure_job_id => $erasure_job_id },
            created_at  => $timestamp,
        }
    );

    return { erasure_job_id => $erasure_job_id, action => $action };
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

1;
