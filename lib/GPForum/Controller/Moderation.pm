# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Moderation;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'GPForum::Controller::Moderation::Base', -signatures;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

sub reports ($self) {
    my $user_id =
      $self->authorized_user_id( $self->moderation_access->view_queue_action );
    if ( !$user_id ) {
        return;
    }

    my $status = $self->status_param;
    my $rows   = eval {
        return $self->gp_report_store->list_queue(
            {
                status => $status,
                limit  => $self->queue_limit,
            }
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("moderation report queue failed: $EVAL_ERROR");
        return $self->system_failure;
    }

    return $self->render_payload(
        {
            payload => $self->gp_moderation_view_model->reports_page(
                csrf_token => $self->csrf_token,
                reports    => $self->_with_command_ids($rows),
                status     => $status,
            ),
            status   => $HTTP_OK,
            template => 'moderation/reports',
        }
    );
}

sub actions ($self) {
    my $user_id = $self->authorized_user_id(
        $self->moderation_access->moderation_resource,
        $self->moderation_access->view_action
    );
    if ( !$user_id ) {
        return;
    }

    my $page = eval {
        return $self->gp_moderation_review_reader->list_actions(
            {
                after       => $self->optional_param('after'),
                limit       => $self->queue_limit,
                target_id   => $self->optional_param('target_id'),
                target_type => $self->optional_param('target_type'),
            }
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("moderation action history failed: $EVAL_ERROR");
        return $self->system_failure;
    }

    return $self->render_payload(
        {
            payload => $self->gp_moderation_view_model->actions_page(
                csrf_token  => $self->csrf_token,
                page        => $self->_actions_page_with_command_ids($page),
                target_id   => $self->optional_param('target_id'),
                target_type => $self->optional_param('target_type'),
            ),
            status   => $HTTP_OK,
            template => 'moderation/actions',
        }
    );
}

sub suspensions ($self) {
    my $user_id = $self->authorized_user_id(
        $self->moderation_access->suspension_resource,
        $self->moderation_access->view_action
    );
    if ( !$user_id ) {
        return;
    }

    my $status = $self->suspension_status_param;
    my $page   = eval {
        return $self->gp_moderation_review_reader->list_suspensions(
            {
                after   => $self->optional_param('after'),
                limit   => $self->queue_limit,
                status  => $status,
                user_id => $self->optional_param('user_id'),
            }
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("moderation suspensions failed: $EVAL_ERROR");
        return $self->system_failure;
    }

    return $self->render_payload(
        {
            payload => $self->gp_moderation_view_model->suspensions_page(
                csrf_token => $self->csrf_token,
                page       => $self->_suspensions_page_with_command_ids($page),
                status     => $status,
                user_id    => $self->optional_param('user_id'),
            ),
            status   => $HTTP_OK,
            template => 'moderation/suspensions',
        }
    );
}

sub _actions_page_with_command_ids ( $self, $page ) {
    $page ||= {};

    return { %{$page}, items => $self->_with_command_ids( $page->{items} ), };
}

sub _suspensions_page_with_command_ids ( $self, $page ) {
    $page ||= {};

    return { %{$page},
        items => $self->_with_revoke_command_ids( $page->{items} ), };
}

sub _with_revoke_command_ids ( $self, $rows ) {
    return [ map { $self->_with_revoke_command_id($_) } @{ $rows || [] } ];
}

sub _with_revoke_command_id ( $self, $row ) {
    return { %{ $self->_row_hash($row) },
        revoke_command_id => $self->gp_id->uuid, };
}

sub _with_command_ids ( $self, $rows ) {
    return [ map { $self->_with_command_id($_) } @{ $rows || [] } ];
}

sub _with_command_id ( $self, $row ) {
    my $hash = $self->_row_hash($row);

    return {
        %{$hash},
        assign_command_id => $self->gp_id->uuid,
        command_id        => $self->gp_id->uuid,

        # Distinct from command_id. A thread report renders a hide form and a
        # lock form at the same time, and both used to carry command_id. The
        # idempotency key is the command id alone -- no action, no route -- so
        # the second submission found the first command's row and replayed its
        # response without running the lock. The moderator saw success and the
        # thread stayed unlocked.
        lock_command_id    => $self->gp_id->uuid,
        release_command_id => $self->gp_id->uuid,
        resolve_command_id => $self->gp_id->uuid,
        reverse_command_id => $self->gp_id->uuid,
        suspend_command_id => $self->_suspend_command_id($hash),
    };
}

sub _suspend_command_id ( $self, $hash ) {
    if ( ( $hash->{target_type} || q{} ) eq 'user' ) {
        return $self->gp_id->uuid;
    }

    return q{};
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

GPForum::Controller::Moderation - Moderation review pages.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/moderation/reports')->to('Moderation#reports');

=head1 DESCRIPTION

Renders authorized report queue, action history, and suspension review pages.
Permission action and resource names live on L<GPForum::Web::ModerationAccess>.
Reader failures stay logged here.

=head1 SUBROUTINES/METHODS

=head2 reports

Renders the moderation report queue.

=head2 actions

Renders keyset-paginated moderation action history.

=head2 suspensions

Renders active or historical suspensions.

=head1 DIAGNOSTICS

Unauthorized, forbidden, and reader failures use the shared moderation helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses report and review-reader helpers configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Moderation::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Write commands live in sibling queue, action, and suspension controllers.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
