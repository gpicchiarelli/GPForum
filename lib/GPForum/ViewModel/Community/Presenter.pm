# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::ViewModel::Community::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base', -signatures;

use GPForum::ViewModel::Notifications::Presenter;

our $VERSION = '0.001';

has notifications_presenter =>
  sub { return GPForum::ViewModel::Notifications::Presenter->new; };

sub bookmarks_page ( $self, %input ) {
    my $page = $input{page} || {};

    return {
        bookmarks => [ map { $self->bookmark($_) } @{ $page->{items} || [] } ],
        next_cursor => $page->{next_cursor},
    };
}

sub feed_page ( $self, %input ) {
    my $page = $input{page} || {};

    return {
        feed_items =>
          [ map { $self->feed_item($_) } @{ $page->{items} || [] } ],
        next_cursor => $page->{next_cursor},
    };
}

sub bookmark_response ( $self, $status, $bookmark ) {
    return {
        bookmark => $bookmark,
        status   => $status,
    };
}

sub subscription_response ( $self, $status, $subscription ) {
    return {
        status       => $status,
        subscription => $subscription,
    };
}

sub notifications_page ( $self, %input ) {
    return $self->notifications_presenter->notifications_page(%input);
}

sub mentions_page ( $self, %input ) {
    return $self->notifications_presenter->mentions_page(%input);
}

sub bookmark ( $self, $row ) {
    return {
        bookmark_id => $self->column( $row, 'bookmark_id' ),
        created_at  => $self->column( $row, 'created_at' ),
        note        => $self->column( $row, 'note' ),
        target_id   => $self->column( $row, 'target_id' ),
        target_type => $self->column( $row, 'target_type' ),
    };
}

sub feed_item ( $self, $row ) {
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

sub notification ( $self, $row, %input ) {
    return $self->notifications_presenter->notification( $row, %input );
}

sub mention ( $self, $row, %input ) {
    return $self->notifications_presenter->mention( $row, %input );
}

1;
