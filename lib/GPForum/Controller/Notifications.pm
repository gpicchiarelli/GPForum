package GPForum::Controller::Notifications;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'GPForum::Controller::Notifications::Base';

our $VERSION = '0.001';

const my $HTTP_OK => 200;

sub inbox {
    my ($self) = @_;

    my $user_id = $self->member_user_id;
    if ( !$user_id ) {
        return;
    }

    my $result = eval { return $self->_inbox_lookup($user_id); };
    if ($EVAL_ERROR) {
        return $self->_system_failure;
    }

    return $self->render_payload(
        {
            payload => $self->gp_notifications_view_model->notifications_page(
                locale       => $self->ui_locale,
                page         => $result->{page},
                renderer     => $self->gp_notification_renderer,
                unread_count => $result->{unread_count},
            ),
            status   => $HTTP_OK,
            template => 'notifications/inbox',
        }
    );
}

sub _inbox_lookup {
    my ( $self, $user_id ) = @_;

    return {
        page => $self->gp_notification_dispatcher->list_page_for_user(
            $user_id,
            {
                after => $self->param('after'),
                limit => $self->page_limit,
            }
        ),
        unread_count =>
          $self->gp_notification_dispatcher->unread_count_for_user($user_id),
    };
}

1;

__END__

=head1 NAME

GPForum::Controller::Notifications - Notification inbox reads.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/notifications')->to('Notifications#inbox');

=head1 DESCRIPTION

Lists notification inbox rows for the authenticated member. Mark-read writes
live on L<GPForum::Controller::Notifications::Read>. Mentions live on
L<GPForum::Controller::Notifications::Mentions>.

=head1 SUBROUTINES/METHODS

=head2 inbox

Renders the notification inbox page or JSON payload.

=head1 DIAGNOSTICS

Anonymous reads return unauthorized. Dispatcher exceptions map to a system
failure.

=head1 CONFIGURATION AND ENVIRONMENT

Uses notification dispatcher and view-model helpers registered during
application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Notifications::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Unread counts remain a dispatcher read, not a write workflow.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
