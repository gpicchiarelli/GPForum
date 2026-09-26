# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Privacy;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'GPForum::Controller::Privacy::Base', -signatures;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

sub dashboard ($self) {
    my $user_id = $self->member_user_id;
    if ( !$user_id ) {
        return;
    }

    my $payload = eval { return $self->_dashboard_payload($user_id); };
    if ($EVAL_ERROR) {
        $self->app->log->error("privacy dashboard failed: $EVAL_ERROR");
        return $self->system_failure;
    }

    return $self->render_payload(
        {
            payload  => $payload,
            status   => $HTTP_OK,
            template => 'privacy/dashboard',
        }
    );
}

sub download_export ($self) {
    my $user_id = $self->member_user_id;
    if ( !$user_id ) {
        return;
    }

    return $self->_download_completed_export($user_id);
}

sub _download_completed_export ( $self, $user_id ) {
    my $row =
      $self->gp_data_rights_review->completed_export_for_user( $user_id,
        $self->param('export_request_id'),
      );
    if ( !$row ) {
        return $self->_not_found('export request not found');
    }

    return $self->render_export_download($row);
}

sub _dashboard_payload ( $self, $user_id ) {
    my $limit = $self->limit_param;

    return $self->gp_privacy_view_model->dashboard(
        active_holds => $self->gp_data_rights_review->active_holds_for_user(
            $user_id, { limit => $limit },
        ),
        csrf_token          => $self->csrf_token,
        deletion_command_id => $self->gp_id->uuid,
        deletion_requests   =>
          $self->gp_data_rights_review->deletion_requests_for_user(
            $user_id, { limit => $limit },
          ),
        export_command_id => $self->gp_id->uuid,
        export_requests   =>
          $self->gp_data_rights_review->export_requests_for_user(
            $user_id, { limit => $limit },
          ),
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Privacy - Member privacy dashboard.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/privacy')->to('Privacy#dashboard');

=head1 DESCRIPTION

Renders the authenticated member privacy dashboard. Export and deletion writes
live in C<Privacy::Requests>; staff review lives in C<Privacy::Review>.

=head1 SUBROUTINES/METHODS

=head2 dashboard

Renders the member export, deletion, and hold summary.

=head2 download_export

Sends the completed export bundle as a JSON attachment for the signed-in
subject. Missing or foreign requests return 404.

=head1 DIAGNOSTICS

Anonymous access and reader failures use the shared privacy helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses privacy view-model and review helpers configured during application
startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Privacy::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Write commands live in sibling request and review controllers.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
