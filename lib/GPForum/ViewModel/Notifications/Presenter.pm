# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::ViewModel::Notifications::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base', -signatures;

our $VERSION = '0.001';

sub notifications_page ( $self, %input ) {
    my $page = $input{page} || {};

    return {
        next_cursor   => $page->{next_cursor},
        notifications => [
            map {
                $self->notification(
                    $_,
                    locale   => $input{locale},
                    renderer => $input{renderer},
                )
            } @{ $page->{items} || [] }
        ],
        unread_count => $input{unread_count} || 0,
    };
}

sub mentions_page ( $self, %input ) {
    my $page = $input{page} || {};

    return {
        mentions => [
            map {
                $self->mention(
                    $_,
                    locale   => $input{locale},
                    renderer => $input{renderer},
                )
            } @{ $page->{items} || [] }
        ],
        next_cursor => $page->{next_cursor},
    };
}

sub mark_read_response ( $self, $read ) {
    return {
        read         => $read,
        status       => 'read',
        unread_count => $read->{unread_count},
    };
}

sub mark_all_read_response ( $self, $read ) {
    return {
        marked_count => $read->{marked_count} || 0,
        status       => 'all_read',
        unread_count => $read->{unread_count},
    };
}

sub notification ( $self, $row, %input ) {
    my $notification = $self->_related_notification($row);
    my $payload      = {
        created_at        => $self->column( $row, 'created_at' ),
        notification_id   => $self->column( $row, 'notification_id' ),
        notification_type =>
          $self->column( $notification, 'notification_type' ),
        payload => $self->inflated_column( $notification, 'payload' ) || {},
        rank_score        => $self->column( $row, 'rank_score' ),
        read_at           => $self->column( $row, 'read_at' ),
        recipient_user_id => $self->column( $row, 'recipient_user_id' ),
        source_id         => $self->column( $notification, 'source_id' ),
        source_type       => $self->column( $notification, 'source_type' ),
        ui                => {
                heading_id => 'notification-'
              . $self->string( $self->column( $row, 'notification_id' ) )
              . '-heading',
        },
    };
    $payload->{presentation} =
      $input{renderer}->render_inbox_item( $input{locale}, $payload )
      if $input{renderer};

    return $payload;
}

sub mention ( $self, $row, %input ) {
    my $username = $self->column( $row, 'actor_username' );
    my $payload  = {
        actor_display_name  => $self->column( $row, 'actor_display_name' ),
        actor_id            => $self->column( $row, 'actor_id' ),
        actor_profile_label => $self->profile_label($username),
        actor_username      => $username,
        created_at          => $self->column( $row, 'created_at' ),
        mention_id          => $self->column( $row, 'mention_id' ),
        mentioned_user_id   => $self->column( $row, 'mentioned_user_id' ),
        mentioned_username  => $self->column( $row, 'mentioned_username' ),
        source_id           => $self->column( $row, 'source_id' ),
        source_type         => $self->column( $row, 'source_type' ),
        ui                  => {
                heading_id => 'mention-'
              . $self->string( $self->column( $row, 'mention_id' ) )
              . '-heading',
        },
    };
    $payload->{presentation} =
      $input{renderer}->render_mention( $input{locale}, $payload )
      if $input{renderer};

    return $payload;
}

sub _related_notification ( $self, $row ) {
    return $row
      if ref $row eq 'HASH' && exists $row->{notification_type};
    my $undefined;
    return $undefined
      if !$row || ref $row eq 'HASH' || !$row->can('notification');

    return $row->notification;
}

1;
