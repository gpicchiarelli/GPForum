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
        reply_count      => _column( $row, 'reply_count' ),
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

__END__

=head1 NAME

GPForum::Service::Forum::HomePageReader - The categories and latest public threads the home page shows.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $reader = GPForum::Service::Forum::HomePageReader->new(
        category_reader => $category_reader,
        thread_reader   => $thread_reader,
    );
    my $home = $reader->home_page(
        {
            after          => $cursor,
            category_limit => 12,
            thread_limit   => 20,
            viewer         => $viewer,
        }
    );
    # { categories => [...], latest_threads => { items => [...], next_cursor => ... } }

=head1 DESCRIPTION

Puts the home page's data together from two readers: the categories the
viewer can read, from L<GPForum::Service::Forum::CategoryReader>, and a
keyset page of the latest public threads, from
L<GPForum::Service::Forum::ThreadReader/list_public_threads>. Each row is
turned into a plain hash of the columns the page uses, so the controller
and the template see the same shape whether the readers return resultset
rows or hashes.

When C<category_reader> or C<thread_reader> is not set, a reader is built
on C<schema> for each call.

=head1 SUBROUTINES/METHODS

=head2 home_page

Takes an optional hash reference with C<category_limit> (default 12, at
most 50), C<thread_limit> (default 20, at most 50), C<after> (the latest
threads' cursor string) and C<viewer>. Returns a hash reference with:

=over 4

=item C<categories>

An array reference of hashes with C<category_id>, C<description>,
C<position>, C<slug>, C<title> and C<visibility>.

=item C<latest_threads>

A hash reference with C<items>, an array reference of hashes with
C<author_user_id>, C<category_id>, C<created_at>, C<deleted_at>,
C<last_activity_at>, C<moderation_state>, C<pinned>, C<reply_count>,
C<safe_excerpt>, C<slug>, C<thread_id>, C<title> and C<visibility>, and
C<next_cursor>, the
cursor of the next page or undef. C<safe_excerpt> is undef when the row's
source has no such column.

=back

The readers bound the limits again on their side.

=head1 DIAGNOSTICS

Nothing of its own; errors from the readers and the database propagate.
The home page controller catches them and renders the page as unavailable.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::Row>, L<GPForum::Service::Forum::CategoryReader>,
L<GPForum::Service::Forum::ThreadReader>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
