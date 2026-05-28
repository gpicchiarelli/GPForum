package GPForum::ViewModel::Community::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base';

use GPForum::ViewModel::Notifications::Presenter;

our $VERSION = '0.001';

has notifications_presenter =>
  sub { return GPForum::ViewModel::Notifications::Presenter->new; };

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

sub bookmark_response {
    my ( $self, $status, $bookmark ) = @_;

    return {
        bookmark => $bookmark,
        status   => $status,
    };
}

sub subscription_response {
    my ( $self, $status, $subscription ) = @_;

    return {
        status       => $status,
        subscription => $subscription,
    };
}

sub notifications_page {
    my ( $self, %input ) = @_;

    return $self->notifications_presenter->notifications_page(%input);
}

sub mentions_page {
    my ( $self, %input ) = @_;

    return $self->notifications_presenter->mentions_page(%input);
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

    return $self->notifications_presenter->notification( $row, %input );
}

sub mention {
    my ( $self, $row, %input ) = @_;

    return $self->notifications_presenter->mention( $row, %input );
}

1;
