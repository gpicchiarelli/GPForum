package GPForum::Controller::Notifications::Mentions;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'GPForum::Controller::Notifications::Base';

our $VERSION = '0.001';

const my $HTTP_OK => 200;

sub mentions {
    my ($self) = @_;

    my $user_id = $self->member_user_id;
    if ( !$user_id ) {
        return;
    }

    my $page = eval { return $self->_mentions_page($user_id); };
    if ($EVAL_ERROR) {
        return $self->_system_failure;
    }

    return $self->render_payload(
        {
            payload => $self->gp_notifications_view_model->mentions_page(
                locale   => $self->ui_locale,
                page     => $page,
                renderer => $self->gp_notification_renderer,
            ),
            status   => $HTTP_OK,
            template => 'notifications/mentions',
        }
    );
}

sub _mentions_page {
    my ( $self, $user_id ) = @_;

    return $self->gp_mention_reader->list_page_for_recipient(
        $user_id,
        {
            after => $self->param('after'),
            limit => $self->page_limit,
        }
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Notifications::Mentions - Mention inbox reads.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/mentions')->to('Notifications::Mentions#mentions');

=head1 DESCRIPTION

Lists mention rows for the authenticated member.

=head1 SUBROUTINES/METHODS

=head2 mentions

Renders the mention inbox page or JSON payload.

=head1 DIAGNOSTICS

Anonymous reads return unauthorized. Reader exceptions map to a system
failure.

=head1 CONFIGURATION AND ENVIRONMENT

Uses mention reader and notification view-model helpers registered during
application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Notifications::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Notification inbox listing remains on the parent notifications controller.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
