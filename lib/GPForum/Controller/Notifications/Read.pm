# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Notifications::Read;

use strict;
use warnings;

use Mojo::Base 'GPForum::Controller::Notifications::Base', -signatures;

our $VERSION = '0.001';

sub mark_read ($self) {
    my $user_id = $self->write_user_id('notification.read');
    if ( !$user_id ) {
        return;
    }

    return $self->mark_read_response(
        $self->gp_notification_workflow->mark_read(
            {
                notification_id => $self->param('notification_id'),
                user_id         => $user_id,
            }
        ),
    );
}

sub mark_all_read ($self) {
    my $user_id = $self->write_user_id('notification.read');
    if ( !$user_id ) {
        return;
    }

    return $self->mark_all_read_response(
        $self->gp_notification_workflow->mark_all_read(
            {
                user_id => $user_id,
            }
        ),
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Notifications::Read - Notification mark-read writes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->post('/notifications/:notification_id/read')
      ->to('Notifications::Read#mark_read');
    $routes->post('/notifications/read-all')
      ->to('Notifications::Read#mark_all_read');

=head1 DESCRIPTION

Marks recipient inbox rows read through the notification workflow.

=head1 SUBROUTINES/METHODS

=head2 mark_read

Marks one notification read for the authenticated member.

=head2 mark_all_read

Marks every unread inbox row for the authenticated member.

=head1 DIAGNOSTICS

CSRF, auth, rate-limit, and missing-row failures use the shared notification
helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the notification workflow helper configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Notifications::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Inbox listing remains on the parent notifications controller.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
