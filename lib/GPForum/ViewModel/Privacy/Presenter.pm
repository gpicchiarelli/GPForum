package GPForum::ViewModel::Privacy::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base';

our $VERSION = '0.001';

sub dashboard {
    my ( $self, %input ) = @_;

    return {
        active_holds =>
          [ map { $self->retention_hold($_) } @{ $input{active_holds} || [] } ],
        csrf_token        => $input{csrf_token},
        deletion_requests => [
            map { $self->deletion_request($_) }
              @{ $input{deletion_requests} || [] }
        ],
        export_requests => [
            map { $self->export_request($_) } @{ $input{export_requests} || [] }
        ],
    };
}

sub review {
    my ( $self, %input ) = @_;

    return {
        active_holds =>
          [ map { $self->retention_hold($_) } @{ $input{active_holds} || [] } ],
        csrf_token        => $input{csrf_token},
        deletion_requests => [
            map { $self->deletion_request($_) }
              @{ $input{deletion_requests} || [] }
        ],
        erasure_jobs =>
          [ map { $self->erasure_job($_) } @{ $input{erasure_jobs} || [] } ],
        export_requests => [
            map { $self->export_request($_) } @{ $input{export_requests} || [] }
        ],
    };
}

sub deletion_request {
    my ( $self, $row ) = @_;

    return {
        completed_at        => $self->column( $row, 'completed_at' ),
        created_at          => $self->column( $row, 'created_at' ),
        deletion_request_id => $self->column( $row, 'deletion_request_id' ),
        reason              => $self->column( $row, 'reason' ),
        request_type        => $self->column( $row, 'request_type' ),
        requester_user_id   => $self->column( $row, 'requester_user_id' ),
        resource_id         => $self->column( $row, 'resource_id' ),
        resource_type       => $self->column( $row, 'resource_type' ),
        status              => $self->column( $row, 'status' ),
    };
}

sub export_request {
    my ( $self, $row ) = @_;

    return {
        created_at        => $self->column( $row, 'created_at' ),
        export_request_id => $self->column( $row, 'export_request_id' ),
        export_type       => $self->column( $row, 'export_type' ),
        finished_at       => $self->column( $row, 'finished_at' ),
        format            => $self->column( $row, 'format' ),
        manifest          => $self->column( $row, 'manifest' ) || {},
        requester_user_id => $self->column( $row, 'requester_user_id' ),
        status            => $self->column( $row, 'status' ),
        subject_user_id   => $self->column( $row, 'subject_user_id' ),
    };
}

sub retention_hold {
    my ( $self, $row ) = @_;

    return {
        created_at        => $self->column( $row, 'created_at' ),
        created_by        => $self->column( $row, 'created_by' ),
        ends_at           => $self->column( $row, 'ends_at' ),
        reason            => $self->column( $row, 'reason' ),
        resource_id       => $self->column( $row, 'resource_id' ),
        resource_type     => $self->column( $row, 'resource_type' ),
        retention_hold_id => $self->column( $row, 'retention_hold_id' ),
        starts_at         => $self->column( $row, 'starts_at' ),
    };
}

sub erasure_job {
    my ( $self, $row ) = @_;

    return {
        completed_at        => $self->column( $row, 'completed_at' ),
        deletion_request_id => $self->column( $row, 'deletion_request_id' ),
        erasure_job_id      => $self->column( $row, 'erasure_job_id' ),
        last_error          => $self->column( $row, 'last_error' ),
        scheduled_at        => $self->column( $row, 'scheduled_at' ),
        status              => $self->column( $row, 'status' ),
    };
}

sub deletion_review {
    my ( $self, $result ) = @_;

    return {
        error      => $result->{error},
        idempotent => $result->{idempotent} || 0,
        job        => $result->{job},
        ok         => $result->{ok} || 0,
        request_id => $result->{request_id},
    };
}

1;
