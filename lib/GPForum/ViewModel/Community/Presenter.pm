package GPForum::ViewModel::Community::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base';

our $VERSION = '0.001';

sub bookmarks_page {
    my ( $self, %input ) = @_;

    my $page = $input{page} || {};

    return {
        bookmarks => [ map { $self->bookmark($_) } @{ $page->{items} || [] } ],
        next_cursor => $page->{next_cursor},
    };
}

sub feed_page {
    my ( $self, %input ) = @_;

    my $page = $input{page} || {};

    return {
        feed_items =>
          [ map { $self->feed_item($_) } @{ $page->{items} || [] } ],
        next_cursor => $page->{next_cursor},
    };
}

sub notifications_page {
    my ( $self, %input ) = @_;

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

sub mentions_page {
    my ( $self, %input ) = @_;

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

sub bookmark {
    my ( $self, $row ) = @_;

    return {
        bookmark_id => $self->column( $row, 'bookmark_id' ),
        created_at  => $self->column( $row, 'created_at' ),
        note        => $self->column( $row, 'note' ),
        target_id   => $self->column( $row, 'target_id' ),
        target_type => $self->column( $row, 'target_type' ),
    };
}

sub feed_item {
    my ( $self, $row ) = @_;

    return {
        created_at         => $self->column( $row, 'created_at' ),
        item_id            => $self->column( $row, 'item_id' ),
        item_type          => $self->column( $row, 'item_type' ),
        permission_version => $self->column( $row, 'permission_version' ),
        rank_score         => $self->column( $row, 'rank_score' ),
        user_id            => $self->column( $row, 'user_id' ),
        visibility_version => $self->column( $row, 'visibility_version' ),
    };
}

sub notification {
    my ( $self, $row, %input ) = @_;

    my $notification = $self->_related_notification($row);
    my $payload      = {
        created_at        => $self->column( $row, 'created_at' ),
        notification_id   => $self->column( $row, 'notification_id' ),
        notification_type =>
          $self->column( $notification, 'notification_type' ),
        payload           => $self->column( $notification, 'payload' ) || {},
        rank_score        => $self->column( $row,          'rank_score' ),
        read_at           => $self->column( $row,          'read_at' ),
        recipient_user_id => $self->column( $row, 'recipient_user_id' ),
        source_id         => $self->column( $notification, 'source_id' ),
        source_type       => $self->column( $notification, 'source_type' ),
    };
    $payload->{presentation} =
      $input{renderer}->render_inbox_item( $input{locale}, $payload )
      if $input{renderer};

    return $payload;
}

sub mention {
    my ( $self, $row, %input ) = @_;

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
    };
    $payload->{presentation} =
      $input{renderer}->render_mention( $input{locale}, $payload )
      if $input{renderer};

    return $payload;
}

sub _related_notification {
    my ( $self, $row ) = @_;

    return $row
      if ref $row eq 'HASH' && exists $row->{notification_type};
    return if !$row || ref $row eq 'HASH' || !$row->can('notification');

    return $row->notification;
}

1;
