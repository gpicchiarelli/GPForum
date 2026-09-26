# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Moderation::Queue;

use strict;
use warnings;

use Mojo::Base 'GPForum::Controller::Moderation::Base', -signatures;

our $VERSION = '0.001';

sub assign_report ($self) {
    my $access  = $self->moderation_access;
    my $user_id = $self->authorized_write_user_id( $access->assign_action );
    if ( !$user_id ) {
        return;
    }

    return $self->report_write_response(
        $self->gp_moderation_workflow->assign_report(
            {
                actor_user_id => $user_id,
                command_id    => $self->command_id_param,
                report_id     => $self->param('report_id'),
            }
        ),
        $access->assigned_status,
    );
}

sub release_report ($self) {
    my $access  = $self->moderation_access;
    my $user_id = $self->authorized_write_user_id( $access->assign_action );
    if ( !$user_id ) {
        return;
    }

    return $self->report_write_response(
        $self->gp_moderation_workflow->release_report(
            {
                actor_user_id => $user_id,
                command_id    => $self->command_id_param,
                report_id     => $self->param('report_id'),
            }
        ),
        $access->released_status,
    );
}

sub resolve_report ($self) {
    my $access  = $self->moderation_access;
    my $user_id = $self->authorized_write_user_id( $access->resolve_action );
    if ( !$user_id ) {
        return;
    }

    return $self->report_write_response(
        $self->gp_moderation_workflow->resolve_report(
            {
                actor_user_id => $user_id,
                command_id    => $self->command_id_param,
                report_id     => $self->param('report_id'),
                resolution    => $self->param('resolution'),
            }
        ),
        $access->resolved_status,
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Moderation::Queue - Report queue write commands.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->post('/moderation/reports/:report_id/assign')
      ->to('Moderation::Queue#assign_report');

=head1 DESCRIPTION

Assigns, releases, and resolves moderation reports through the moderation
workflow. Permission names and write-success statuses live on
L<GPForum::Web::ModerationAccess>.

=head1 SUBROUTINES/METHODS

=head2 assign_report

Assigns a report to the current moderator.

=head2 release_report

Releases a report assignment.

=head2 resolve_report

Resolves a report with an explicit resolution.

=head1 DIAGNOSTICS

CSRF, auth, validation, and missing-report failures use the shared moderation
helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the moderation workflow helper configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Moderation::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Read-only queue listing remains on the parent moderation controller.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
