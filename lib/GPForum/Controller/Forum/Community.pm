# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Forum::Community;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'GPForum::Controller::Forum::Base', -signatures;

our $VERSION = '0.001';

const my $HTTP_OK => 200;

sub feed ($self) {
    my $user_id = $self->_current_user_id;
    if ( !$user_id ) {
        return $self->_unauthorized;
    }

    my $page = $self->gp_feed_reader->list_page_for_user(
        $user_id,
        {
            limit  => $self->list_page_limit,
            after  => $self->param('after'),
            viewer => $self->gp_forum_viewer,
        }
    );

    my $payload = $self->gp_community_view_model->feed_page( page => $page );

    return $self->render_payload(
        {
            controller => $self,
            payload    => $payload,
            status     => $HTTP_OK,
            template   => 'forum/feed',
        }
    );
}

sub bookmarks ($self) {
    my $user_id = $self->_current_user_id;
    if ( !$user_id ) {
        return $self->_unauthorized;
    }

    my $page = $self->gp_bookmark_store->list_page_for_user(
        $user_id,
        {
            target_type => $self->forum_access->thread_target,
            limit       => $self->list_page_limit,
            after       => $self->param('after'),
            viewer      => $self->gp_forum_viewer,
        }
    );

    my $payload =
      $self->gp_community_view_model->bookmarks_page( page => $page );

    return $self->render_payload(
        {
            controller => $self,
            payload    => $payload,
            status     => $HTTP_OK,
            template   => 'forum/bookmarks',
        }
    );
}

sub create_thread_bookmark ($self) {
    my $user_id = $self->write_user_id('thread.bookmark');
    if ( !$user_id ) {
        return;
    }
    if ( !$self->visible_thread ) {
        return;
    }

    return $self->_save_thread_bookmark($user_id);
}

sub _save_thread_bookmark ( $self, $user_id ) {
    return $self->_community_write_response(
        'bookmark',
        $self->forum_access->bookmarked_status,
        $self->gp_community_workflow->save_bookmark(
            {
                command_id  => $self->command_id_param,
                note        => $self->param('note'),
                target_id   => $self->param('thread_id'),
                target_type => $self->forum_access->thread_target,
                user_id     => $user_id,
            }
        ),
    );
}

sub remove_thread_bookmark ($self) {
    my $user_id = $self->write_user_id('thread.bookmark.remove');
    if ( !$user_id ) {
        return;
    }
    if ( !$self->visible_thread ) {
        return;
    }

    return $self->_delete_thread_bookmark($user_id);
}

sub _delete_thread_bookmark ( $self, $user_id ) {
    return $self->_community_write_response(
        'bookmark',
        $self->forum_access->bookmark_removed_status,
        $self->gp_community_workflow->remove_bookmark(
            {
                command_id  => $self->command_id_param,
                target_id   => $self->param('thread_id'),
                target_type => $self->forum_access->thread_target,
                user_id     => $user_id,
            }
        ),
    );
}

sub subscribe_thread ($self) {
    my $user_id = $self->write_user_id('thread.subscribe');
    if ( !$user_id ) {
        return;
    }
    if ( !$self->visible_thread ) {
        return;
    }

    return $self->_save_thread_subscription($user_id);
}

sub _save_thread_subscription ( $self, $user_id ) {
    return $self->_community_write_response(
        'subscription',
        $self->forum_access->subscribed_status,
        $self->gp_community_workflow->save_subscription(
            {
                command_id  => $self->command_id_param,
                preference  => $self->param('preference') || 'all',
                target_id   => $self->param('thread_id'),
                target_type => $self->forum_access->thread_target,
                user_id     => $user_id,
            }
        ),
    );
}

sub mute_thread_subscription ($self) {
    my $user_id = $self->write_user_id('thread.subscription.mute');
    if ( !$user_id ) {
        return;
    }
    if ( !$self->visible_thread ) {
        return;
    }

    return $self->_mute_visible_subscription($user_id);
}

sub _mute_visible_subscription ( $self, $user_id ) {
    return $self->_community_write_response(
        'subscription',
        $self->forum_access->subscription_muted_status,
        $self->gp_community_workflow->mute_subscription(
            {
                command_id  => $self->command_id_param,
                target_id   => $self->param('thread_id'),
                target_type => $self->forum_access->thread_target,
                user_id     => $user_id,
            }
        ),
    );
}

sub unsubscribe_thread ($self) {
    my $user_id = $self->write_user_id('thread.unsubscribe');
    if ( !$user_id ) {
        return;
    }
    if ( !$self->visible_thread ) {
        return;
    }

    return $self->_revoke_visible_subscription($user_id);
}

sub _revoke_visible_subscription ( $self, $user_id ) {
    return $self->_community_write_response(
        'subscription',
        $self->forum_access->unsubscribed_status,
        $self->gp_community_workflow->revoke_subscription(
            {
                command_id  => $self->command_id_param,
                target_id   => $self->param('thread_id'),
                target_type => $self->forum_access->thread_target,
                user_id     => $user_id,
            }
        ),
    );
}

sub _community_write_response ( $self, $kind, $status, $result ) {
    my $failure = $self->_community_write_failure($result);
    if ($failure) {
        return $failure;
    }

    return $self->_community_write_success( $kind, $status, $result );
}

sub _community_write_failure ( $self, $result ) {
    return $self->_community_status_failure( $result, $result->{status} );
}

sub _community_status_failure ( $self, $result, $mapped ) {
    my $undefined;

    if ( !defined $mapped ) {
        return $undefined;
    }
    if ( $mapped eq 'ok' ) {
        return $undefined;
    }

    return $self->_community_error_response( $result, $mapped );
}

sub _community_error_response ( $self, $result, $mapped ) {
    if ( $mapped eq 'failed' ) {
        return $self->_service_unavailable;
    }
    if ( $mapped eq 'not_found' ) {
        return $self->_not_found( $result->{error} );
    }
    if ( $mapped eq 'invalid' ) {
        return $self->_bad_request( $result->{errors} );
    }
    if ( $mapped eq 'conflict' ) {
        return $self->_conflict( $result->{error} );
    }

    my $undefined;
    return $undefined;
}

sub _community_write_success ( $self, $kind, $status, $result ) {
    if ( $kind eq 'bookmark' ) {
        return $self->bookmark_action_response( $status, $result->{stored} );
    }

    return $self->subscription_action_response( $status, $result->{stored} );
}

sub report_thread ($self) {
    my $user_id = $self->write_user_id('report.create');
    if ( !$user_id ) {
        return;
    }

    my $thread = $self->visible_thread;
    if ( !$thread ) {
        return;
    }

    return $self->_submit_thread_report( $user_id, $thread );
}

sub _submit_thread_report ( $self, $user_id, $thread ) {
    my $thread_id = $self->_column( $thread, 'thread_id' );

    return $self->report_response(
        $self->create_report(
            {
                reporter_user_id => $user_id,
                target_type      => $self->forum_access->thread_target,
                target_id        => $thread_id,
            }
        ),
        $thread_id,
        undef,
    );
}

sub report_post ($self) {
    my $user_id = $self->write_user_id('report.create');
    if ( !$user_id ) {
        return;
    }

    return $self->_submit_visible_post_report($user_id);
}

sub _submit_visible_post_report ( $self, $user_id ) {
    my $post =
      $self->gp_post_reader->find_visible_post( $self->param('post_id'),
        $self->gp_forum_viewer );
    if ( !$post ) {
        return $self->_not_found('post not found');
    }

    my $thread_id = $self->_column( $post, 'thread_id' );
    if (
        !$self->gp_thread_detail_reader->find_thread(
            $thread_id, $self->gp_forum_viewer
        )
      )
    {
        return $self->_not_found('post not found');
    }

    return $self->report_response(
        $self->create_report(
            {
                reporter_user_id => $user_id,
                target_type      => $self->forum_access->post_target,
                target_id        => $self->_column( $post, 'post_id' ),
            }
        ),
        $thread_id,
        $self->_column( $post, 'post_id' ),
    );
}

sub report_profile ($self) {
    my $user_id = $self->write_user_id('report.create');
    if ( !$user_id ) {
        return;
    }

    return $self->_submit_profile_report($user_id);
}

sub _submit_profile_report ( $self, $user_id ) {
    my $username = $self->param('username');
    my $profile  = $self->gp_profile_reader->public_profile(
        $username,
        {
            limit => 1,
        }
    );

    if ( !$profile->{ok} ) {
        return $self->_not_found('profile not found');
    }

    return $self->profilereport_response(
        $self->create_report(
            {
                reporter_user_id => $user_id,
                target_type      => $self->forum_access->user_target,
                target_id        => $profile->{profile}{user}{user_id},
            }
        ),
        $profile->{profile}{user}{username} || $username,
    );
}

1;

__END__

=head1 NAME

GPForum::Controller::Forum::Community - Feed, bookmarks, subscriptions, reports.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/feed')->to('Forum::Community#feed');

=head1 DESCRIPTION

Handles authenticated community surfaces around visible threads and profiles.
Bookmark and subscription writes go through
L<GPForum::Service::Community::Workflow> and require HTTP C<command_id>.
Bookmark and report target types and write-success statuses live on
L<GPForum::Web::ForumAccess>.

=head1 SUBROUTINES/METHODS

=head2 feed

Renders the signed-in member feed.

=head2 bookmarks

Renders the signed-in bookmark list.

=head2 create_thread_bookmark

Saves a thread bookmark.

=head2 remove_thread_bookmark

Removes a thread bookmark.

=head2 subscribe_thread

Subscribes the viewer to a visible thread.

=head2 mute_thread_subscription

Mutes an existing thread subscription.

=head2 unsubscribe_thread

Revokes an existing thread subscription.

=head2 report_thread

Creates a thread report.

=head2 report_post

Creates a post report.

=head2 report_profile

Creates a profile report.

=head1 DIAGNOSTICS

Missing threads, bookmarks, and subscriptions render as not found.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the community workflow and stores configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Forum::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Reports require a reason and are rate-limited separately from other writes.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
