# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::HomePageReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Service::Forum::CategoryReader;
use GPForum::Service::Forum::ThreadReader;

our $VERSION = '0.001';

const my $DEFAULT_CATEGORY_LIMIT => 12;
const my $DEFAULT_THREAD_LIMIT   => 20;
const my $MAX_CATEGORY_LIMIT     => 50;
const my $MAX_THREAD_LIMIT       => 50;

has category_reader => undef;
has schema          => undef;
has thread_reader   => undef;

sub home_page ( $self, $request ) {
    my $category_limit =
      _bounded_limit( $request ? $request->{category_limit} : undef,
        $DEFAULT_CATEGORY_LIMIT, $MAX_CATEGORY_LIMIT, );
    my $thread_limit =
      _bounded_limit( $request ? $request->{thread_limit} : undef,
        $DEFAULT_THREAD_LIMIT, $MAX_THREAD_LIMIT, );
    my $after  = $request ? $request->{after}  : undef;
    my $viewer = $request ? $request->{viewer} : undef;

    my $categories = $self->_category_reader->list_categories(
        { limit => $category_limit, viewer => $viewer } );
    my $threads = $self->_thread_reader->list_public_threads(
        {
            after  => $after,
            limit  => $thread_limit,
            viewer => $viewer,
        }
    );

    return {
        categories     => [ map { _category($_) } @{$categories} ],
        latest_threads => {
            items       => [ map { _thread($_) } @{ $threads->{items} } ],
            next_cursor => $threads->{next_cursor},
        },
    };
}

sub _category_reader ($self) {
    return $self->category_reader
      if $self->category_reader;

    return GPForum::Service::Forum::CategoryReader->new(
        schema => $self->schema );
}

sub _thread_reader ($self) {
    return $self->thread_reader
      if $self->thread_reader;

    return GPForum::Service::Forum::ThreadReader->new(
        schema => $self->schema );
}

sub _category ($row) {
    return {
        category_id => _column( $row, 'category_id' ),
        description => _column( $row, 'description' ),
        position    => _column( $row, 'position' ),
        slug        => _column( $row, 'slug' ),
        title       => _column( $row, 'title' ),
        visibility  => _column( $row, 'visibility' ),
    };
}

sub _thread ($row) {
    return {
        author_user_id   => _column( $row, 'author_user_id' ),
        category_id      => _column( $row, 'category_id' ),
        created_at       => _column( $row, 'created_at' ),
        deleted_at       => _column( $row, 'deleted_at' ),
        last_activity_at => _column( $row, 'last_activity_at' ),
        moderation_state => _column( $row, 'moderation_state' ),
        pinned           => _column( $row, 'pinned' ),
        safe_excerpt     => scalar _optional_column( $row, 'safe_excerpt' ),
        slug             => _column( $row, 'slug' ),
        thread_id        => _column( $row, 'thread_id' ),
        title            => _column( $row, 'title' ),
        visibility       => _column( $row, 'visibility' ),
    };
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

sub _optional_column ( $row, $name ) {
    if ( ref $row && $row->can('result_source') ) {
        my $source = $row->result_source;
        return
             if $source
          && $source->can('has_column')
          && !$source->has_column($name);
    }

    return _column( $row, $name );
}

sub _bounded_limit ( $requested, $default, $max ) {
    return $default if !defined $requested;
    return $max     if $requested > $max;
    return int $requested;
}

1;
