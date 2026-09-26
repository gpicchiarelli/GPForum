# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::Readability;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::CountedQuery;
use GPForum::Infrastructure::Id;
use GPForum::Service::Forum::ViewerResolver;
use GPForum::Service::Forum::Visibility;

our $VERSION = '0.001';

const my @PLACEMENT_COLUMNS => qw(
  category_id category_visibility space_id space_visibility
  thread_author thread_visibility post_author post_visibility
);
const my @LEVELS         => qw(space category thread post);
const my %VISIBLE_THREAD => ( visible => 1, locked => 1 );

# Where a source sits, in one statement: its own visibility and state, its
# thread's, and its category's and space's.
const my $PLACEMENT_SQL => {
    post => join( q{ },
        'SELECT p.visibility AS post_visibility,',
        'p.author_user_id AS post_author, p.deleted_at AS post_deleted_at,',
        'p.moderation_state AS post_state,',
        't.visibility AS thread_visibility, t.author_user_id AS thread_author,',
't.deleted_at AS thread_deleted_at, t.moderation_state AS thread_state,',
        'c.category_id, c.visibility AS category_visibility,',
        'c.deleted_at AS category_deleted_at, c.space_id,',
        's.visibility AS space_visibility',
        'FROM posts p JOIN threads t ON t.thread_id = p.thread_id',
        'JOIN categories c ON c.category_id = t.category_id',
        'JOIN spaces s ON s.space_id = c.space_id',
        'WHERE p.post_id = ?' ),
    thread => join( q{ },
        'SELECT t.visibility AS thread_visibility,',
        't.author_user_id AS thread_author,',
't.deleted_at AS thread_deleted_at, t.moderation_state AS thread_state,',
        'c.category_id, c.visibility AS category_visibility,',
        'c.deleted_at AS category_deleted_at, c.space_id,',
        's.visibility AS space_visibility',
        'FROM threads t JOIN categories c ON c.category_id = t.category_id',
        'JOIN spaces s ON s.space_id = c.space_id',
        'WHERE t.thread_id = ?' ),
};

has schema          => undef;
has viewer_resolver => sub ($self) {
    return GPForum::Service::Forum::ViewerResolver->new(
        schema => $self->schema );
};

# ADR 0102: whether a reader may read a post or thread -- its space, its
# category, its thread and the post itself. $reader is a resolved Viewer (a
# request's) or a user id, resolved only when the source is not public. A
# source that is missing, removed or hidden, or of a kind this does not
# know, is readable by nobody.
sub readable_by ( $self, $reader, $source_type, $source_id ) {
    my @readers = $self->readers_of( $source_type, $source_id, $reader );

    return @readers ? 1 : 0;
}

# The readers, of those given, who may read a post or thread: one query for
# where the source sits, and for a source that is not public, each reader's
# viewer. A realtime broadcast filters its subscribers this way.
sub readers_of ( $self, $source_type, $source_id, @readers ) {
    my $resource = $self->_placement( $source_type, $source_id );
    return          if !$resource;
    return @readers if _public($resource);

    return grep {
        GPForum::Service::Forum::Visibility->readable( $self->_viewer($_),
            $resource )
    } @readers;
}

# Rows that point at a post or thread by a type column and an id column --
# notifications, mentions, bookmarks, feed items -- as an SQL condition that
# keeps only those whose source the reader may read, live and not hidden.
# Lists filter with it before LIMIT, so keyset pages stay full (ADR 0102);
# a row of any other type is left out.
#
# Each subquery is correlated on the row's id: PostgreSQL runs it per row as
# a primary-key lookup. Uncorrelated, under the OR it became a hashed subplan
# that read every thread in the forum for a page of twenty-five.
sub sources_condition ( $self, $reader, $type_column, $id_column ) {
    my $viewer = $self->_viewer($reader);

    # The type test first in each arm: PostgreSQL evaluates an AND inside an
    # OR in the order written, so a thread row never runs the post lookup.
    return {
        -or => [
            {
                -and => [
                    { $type_column => 'post' },
                    {
                        $id_column => {
                            -in => $self->_readable_post( $viewer, $id_column )
                        }
                    },
                ]
            },
            {
                -and => [
                    { $type_column => 'thread' },
                    {
                        $id_column => {
                            -in =>
                              $self->_readable_thread( $viewer, $id_column )
                        }
                    },
                ]
            },
        ],
    };
}

sub _readable_thread ( $self, $viewer, $id_column ) {
    my $alias = 'readable_thread';

    return $self->schema->resultset('Thread')->search_rs(
        {
            "$alias.thread_id"        => { -ident => $id_column },
            "$alias.deleted_at"       => undef,
            "$alias.moderation_state" =>
              { -in => [ sort keys %VISIBLE_THREAD ] },
            'category.deleted_at' => undef,
            %{ GPForum::Service::Forum::Visibility->readable_condition(
                    $viewer,
                    {
                        category      => 'category.visibility',
                        category_id   => "$alias.category_id",
                        space         => 'space.visibility',
                        space_id      => 'category.space_id',
                        thread        => "$alias.visibility",
                        thread_author => "$alias.author_user_id",
                    }
                )
            },
        },
        { alias => $alias, join => { category => 'space' } }
    )->get_column("$alias.thread_id")->as_query;
}

sub _readable_post ( $self, $viewer, $id_column ) {
    my $alias = 'readable_post';

    return $self->schema->resultset('Post')->search_rs(
        {
            "$alias.post_id"          => { -ident => $id_column },
            "$alias.deleted_at"       => undef,
            "$alias.moderation_state" => 'visible',
            'thread.deleted_at'       => undef,
            'thread.moderation_state' =>
              { -in => [ sort keys %VISIBLE_THREAD ] },
            'category.deleted_at' => undef,
            %{ GPForum::Service::Forum::Visibility->readable_condition(
                    $viewer,
                    {
                        category      => 'category.visibility',
                        category_id   => 'thread.category_id',
                        post          => "$alias.visibility",
                        post_author   => "$alias.author_user_id",
                        space         => 'space.visibility',
                        space_id      => 'category.space_id',
                        thread        => 'thread.visibility',
                        thread_author => 'thread.author_user_id',
                    }
                )
            },
        },
        { alias => $alias, join => { thread => { category => 'space' } } }
    )->get_column("$alias.post_id")->as_query;
}

sub _placement ( $self, $source_type, $source_id ) {
    my $undefined;

    # exists first: the table is a Const::Fast restricted hash, and reading an
    # unknown key from it dies rather than answering undef.
    my $type = $source_type // q{};
    my $sql  = exists $PLACEMENT_SQL->{$type} ? $PLACEMENT_SQL->{$type} : undef;
    return $undefined
      if !$sql || !GPForum::Infrastructure::Id->is_uuid($source_id);

    my $place =
      GPForum::Infrastructure::CountedQuery->select_row( $self->schema,
        $sql, $source_id );
    return $undefined if !$place || !_live($place);

    return {
        map  { $_ => $place->{$_} }
        grep { exists $place->{$_} } @PLACEMENT_COLUMNS
    };
}

sub _public ($resource) {
    my @levels = map { $resource->{"${_}_visibility"} }
      grep { exists $resource->{"${_}_visibility"} } @LEVELS;

    return GPForum::Service::Forum::Visibility->effective(@levels) eq 'public'
      ? 1
      : 0;
}

sub _viewer ( $self, $reader ) {
    return $reader if ref $reader;

    return $self->viewer_resolver->resolve($reader);
}

sub _live ($place) {
    return 0 if defined $place->{category_deleted_at};
    return 0 if defined $place->{thread_deleted_at};

    # exists: reading a key the restricted hash lacks -- 'hidden' -- dies.
    return 0 if !exists $VISIBLE_THREAD{ $place->{thread_state} // q{} };
    return 1 if !exists $place->{post_state};
    return 0 if defined $place->{post_deleted_at};

    return ( $place->{post_state} // q{} ) eq 'visible' ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::Readability - Who may read a post or thread.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $readability =
      GPForum::Service::Forum::Readability->new( schema => $schema );
    my $ok = $readability->readable_by( $viewer, 'post', $post_id );
    my @subscribers =
      $readability->readers_of( 'thread', $thread_id, @user_ids );

=head1 DESCRIPTION

Effective visibility (ADR 0102) for one post or thread judged away from a
page: the space, the category, the thread and the post, by the rules of
L<GPForum::Service::Forum::Visibility>, and only while the source is live.
Notifications, mentions, attachment downloads and realtime thread channels
ask it.

=head1 SUBROUTINES/METHODS

=head2 readable_by

True when a reader -- a Viewer or a user id -- may read the post or thread.

=head2 readers_of

The readers, of those given, who may read the post or thread, in order.

=head2 sources_condition

An SQL condition, for DBIx::Class, on a row's source type and id columns:
true only for a post or thread the reader may read.

=head1 DIAGNOSTICS

Dies when the database does.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::CountedQuery>,
L<GPForum::Service::Forum::ViewerResolver>,
L<GPForum::Service::Forum::Visibility>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Resolves one viewer per reader of a source that is not public.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
