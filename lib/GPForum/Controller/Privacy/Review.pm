package GPForum::Controller::Privacy::Review;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'GPForum::Controller::Privacy::Base';

our $VERSION = '0.001';

const my $HTTP_OK => 200;

sub review {
    my ($self) = @_;

    my $user_id =
      $self->authorized_user_id( $self->privacy_access->view_action );
    if ( !$user_id ) {
        return;
    }

    my $payload = eval { return $self->_review_payload; };
    if ($EVAL_ERROR) {
        $self->app->log->error("privacy review failed: $EVAL_ERROR");
        return $self->system_failure;
    }

    return $self->render_payload(
        {
            payload  => $payload,
            status   => $HTTP_OK,
            template => 'privacy/review',
        }
    );
}

sub approve_deletion {
    my ($self) = @_;

    my $actor_id = $self->authorized_write_user_id;
    if ( !$actor_id ) {
        return;
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

sub hold_deletion {
    my ($self) = @_;

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

sub run_erasure_job {
    my ($self) = @_;

    my $actor_id = $self->authorized_write_user_id;
    if ( !$actor_id ) {
        return;
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

sub _review_payload {
    my ($self) = @_;

    my $limit = $self->limit_param;

    return $self->gp_privacy_view_model->review(
        active_holds =>
          $self->gp_data_rights_review->active_holds( { limit => $limit }, ),
        csrf_token        => $self->csrf_token,
        deletion_requests => $self->_with_review_command_ids(
            $self->gp_data_rights_review->pending_deletion_requests(
                { limit => $limit },
            )
        ),
        erasure_jobs => $self->_with_erasure_command_ids(
            $self->gp_data_rights_review->erasure_jobs_by_status(
                'pending', { limit => $limit },
            )
        ),
        export_requests =>
          $self->gp_data_rights_review->pending_export_requests(
            { limit => $limit },
          ),
    );
}

sub _with_review_command_ids {
    my ( $self, $rows ) = @_;

    return [ map { $self->_with_review_command_id($_) } @{ $rows || [] } ];
}

sub _with_review_command_id {
    my ( $self, $row ) = @_;

    return {
        %{ $self->_row_hash($row) },
        approve_command_id => $self->gp_id->uuid,
        hold_command_id    => $self->gp_id->uuid,
    };
}

sub _with_erasure_command_ids {
    my ( $self, $rows ) = @_;

    return [ map { $self->_with_write_command_id($_) } @{ $rows || [] } ];
}

sub _with_write_command_id {
    my ( $self, $row ) = @_;

    return { %{ $self->_row_hash($row) }, command_id => $self->gp_id->uuid, };
}

sub _row_hash {
    my ( undef, $row ) = @_;

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
