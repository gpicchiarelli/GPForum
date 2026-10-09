# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Privacy::Review;

use Const::Fast;
use Mojo::Base 'GPForum::Controller::Privacy::Base', -signatures;
use v5.40;

use GPForum::Web::DangerConfirmation;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

sub review ($self) {
    my $user_id =
      $self->authorized_user_id( $self->privacy_access->view_action );
    if ( !$user_id ) {
        return;
    }

    my $payload;
    try {
        $payload = $self->_review_payload;
    }
    catch ($error) {
        $self->app->log->error("privacy review failed: $error");
        return $self->system_failure;
    };

    return $self->render_payload(
        {
            payload  => $payload,
            status   => $HTTP_OK,
            template => 'privacy/review',
        }
    );
}

sub approve_deletion ($self) {
    my $actor_id = $self->authorized_write_user_id;
    if ( !$actor_id ) {
        return;
    }
    if ( my $refused = GPForum::Web::DangerConfirmation->unconfirmed($self) ) {
        return $self->deletion_review_write_response( $refused,
            $self->privacy_access->deletion_approved_status );
    }

    return $self->deletion_review_write_response(
        $self->gp_privacy_workflow->approve_deletion(
            {
                actor_user_id => $actor_id,
                command_id    => $self->command_id_param,
                reason        => $self->param('reason'),
                request_id    => $self->param('request_id'),
            }
        ),
        $self->privacy_access->deletion_approved_status,
    );
}

sub hold_deletion ($self) {
    my $actor_id = $self->authorized_write_user_id;
    if ( !$actor_id ) {
        return;
    }

    return $self->deletion_review_write_response(
        $self->gp_privacy_workflow->hold_deletion(
            {
                actor_user_id => $actor_id,
                command_id    => $self->command_id_param,
                reason        => $self->param('reason'),
                request_id    => $self->param('request_id'),
            }
        ),
        $self->privacy_access->deletion_held_status,
    );
}

sub run_erasure_job ($self) {
    my $actor_id = $self->authorized_write_user_id;
    if ( !$actor_id ) {
        return;
    }
    if ( my $refused = GPForum::Web::DangerConfirmation->unconfirmed($self) ) {
        return $self->erasure_write_response($refused);
    }

    return $self->erasure_write_response(
        $self->gp_privacy_workflow->run_erasure_job(
            {
                actor_user_id => $actor_id,
                command_id    => $self->command_id_param,
                job_id        => $self->param('job_id'),
            }
        ),
    );
}

# Each pending deletion request carries the ids of its approve and hold
# forms, each pending erasure job the id of its run form.
sub _review_payload ($self) {
    my $limit  = $self->limit_param;
    my $review = $self->gp_data_rights_review;
    my $holds  = $review->active_holds( { limit => $limit } );

    my @deletion_requests;
    for my $row (
        @{ $review->pending_deletion_requests( { limit => $limit } ) || [] } )
    {
        push @deletion_requests,
          {
            %{ $self->_row_hash($row) },
            approve_command_id => $self->gp_id->uuid,
            hold_command_id    => $self->gp_id->uuid,
          };
    }

    my @erasure_jobs;
    for my $row (
        @{
            $review->erasure_jobs_by_status( 'pending', { limit => $limit } )
              || []
        }
      )
    {
        push @erasure_jobs,
          { %{ $self->_row_hash($row) }, command_id => $self->gp_id->uuid, };
    }

    return $self->gp_privacy_view_model->review(
        active_holds      => $holds,
        csrf_token        => $self->csrf_token,
        deletion_requests => \@deletion_requests,
        erasure_jobs      => \@erasure_jobs,
        export_requests   =>
          $review->pending_export_requests( { limit => $limit } ),
    );
}

sub _row_hash ( $, $row ) {
    if ( ref $row eq 'HASH' ) {
        return { %{$row} };
    }
    if ( $row && $row->can('get_columns') ) {
        return { $row->get_columns };
    }

    return {};
}

1;

__END__

=head1 NAME

GPForum::Controller::Privacy::Review - Staff privacy review and writes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/admin/privacy')->to('Privacy::Review#review');

=head1 DESCRIPTION

Renders the staff privacy queue and applies approval, legal-hold, and erasure
commands through the privacy workflow. The catalog C<view> action and
review write-success statuses live on L<GPForum::Web::PrivacyAccess>.
Reader failures stay logged here.

=head1 SUBROUTINES/METHODS

=head2 review

Renders pending deletion, export, hold, and erasure rows.

=head2 approve_deletion

Approves a deletion request.

=head2 hold_deletion

Places a legal hold on a deletion request.

=head2 run_erasure_job

Runs a pending erasure job.

=head1 DIAGNOSTICS

CSRF, auth, and workflow failures use the shared privacy helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses privacy review and workflow helpers configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Privacy::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Member dashboard and request writes live in sibling controllers.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
