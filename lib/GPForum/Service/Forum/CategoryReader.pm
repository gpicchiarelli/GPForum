# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::CategoryReader;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Service::Forum::Viewer;
use GPForum::Service::Forum::Visibility;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT             => 100;
const my $MAX_LIMIT                 => 200;
const my $DEFAULT_CACHE_TTL_SECONDS => 30;

has cache             => undef;
has cache_ttl_seconds => sub { return $DEFAULT_CACHE_TTL_SECONDS; };
has schema            => undef;

# ADR 0102: only the categories the viewer can read, judged on the category
# and its space in the query. A request without a viewer reads as anonymous.
# Only an anonymous list is cached: it is the one list every reader shares.
sub list_categories ( $self, $request ) {
    my $limit  = _bounded_limit( $request ? $request->{limit} : undef );
    my $viewer = _viewer($request);

    return $self->_cached_categories($limit)
      if $self->cache && $viewer->is_anonymous;

    return $self->_list_categories( $limit, $viewer );
}

# The category, if it exists and the viewer can read it; otherwise nothing,
# so the caller answers 404 and existence is not confirmed.
sub find_category ( $self, $category_id, $viewer = undef ) {
    my $undefined;
    return $undefined if !defined $category_id || !length $category_id;

    my $row = $self->schema->resultset('Category')->find(
        $category_id,
        {
            join      => 'space',
            '+select' => ['space.visibility'],
            '+as'     => ['space_visibility'],
        }
    );
    return $undefined if !$row;
    return $undefined if defined $row->get_column('deleted_at');
    return $undefined if !_readable_category( $row, $viewer );

    return $row;
}

sub _readable_category ( $row, $viewer ) {
    return GPForum::Service::Forum::Visibility->readable(
        GPForum::Service::Forum::Viewer->from($viewer),
        {
            category_id         => $row->get_column('category_id'),
            category_visibility => $row->get_column('visibility'),
            space_id            => $row->get_column('space_id'),
            space_visibility    => $row->get_column('space_visibility'),
        }
    );
}

sub _viewer ($request) {
    my $viewer = ref $request eq 'HASH' ? $request->{viewer} : undef;

    return $viewer || GPForum::Service::Forum::Viewer->anonymous;
}

sub _cached_categories ( $self, $limit ) {
    my $key = join q{:}, 'categories', 'list', 'anonymous', $limit;

    # Plain column hashes, not rows: GlifiStore holds JSON and a row does not
    # encode, so the list never reached L2 and every fill counted as a shared
    # cache failure. Every reader of the list (the view models, the home page,
    # the sitemap) takes a hash as readily as a row.
    return $self->cache->get_or_set(
        $key,
        sub {
            return [ map { +{ $_->get_columns } }
                  @{ $self->_list_categories($limit) } ];
        },
        {
            tags        => [ 'categories', 'forum-index' ],
            ttl_seconds => $self->cache_ttl_seconds,
        }
    );
}

sub _list_categories ( $self, $limit, $viewer = undef ) {
    return [ _rows( $self->categories_resultset( $limit, $viewer ) ) ];
}

# The resultset the category index executes.
# Public so the query-plan evidence EXPLAINs what actually runs.
sub categories_resultset ( $self, $limit, $viewer = undef ) {
    my $readable = GPForum::Service::Forum::Visibility->readable_condition(
        $viewer || GPForum::Service::Forum::Viewer->anonymous,
        {
            category    => 'me.visibility',
            category_id => 'me.category_id',
            space       => 'space.visibility',
            space_id    => 'me.space_id',
        }
    );

    return $self->schema->resultset('Category')->search_rs(
        { 'me.deleted_at' => undef, %{$readable} },
        {
            join     => 'space',
            order_by => [
                { -asc => 'me.position' },
                { -asc => 'me.title' },
                { -asc => 'me.category_id' },
            ],
            rows => $limit,
        }
    );
}

sub _bounded_limit ($requested) {
    return $DEFAULT_LIMIT if !defined $requested;
    return $DEFAULT_LIMIT if $requested !~ /\A [[:digit:]]+ \z/msx;
    return $DEFAULT_LIMIT if $requested < 1;
    return $MAX_LIMIT     if $requested > $MAX_LIMIT;

    return int $requested;
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::CategoryReader - The categories a viewer can read, with the anonymous list cached.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $reader = GPForum::Service::Forum::CategoryReader->new(
        cache             => $cache,
        cache_ttl_seconds => 30,
        schema            => $schema,
    );
    my $categories =
      $reader->list_categories( { limit => 50, viewer => $viewer } );
    my $category = $reader->find_category( $category_id, $viewer );
    my $rs       = $reader->categories_resultset( 100, $viewer );

=head1 DESCRIPTION

The read side of forum categories: the category index, the home page, the
sitemap, the new thread form and a thread's move form list them through this
module, the category page finds its category with it, and the posting
workflow checks with it the category a thread is created in or moved to.

Visibility follows ADR 0102. A category is listed or found only when the
viewer can read both the category and its space, judged by
L<GPForum::Service::Forum::Visibility>. The list applies that rule in the
query, before the row limit, so a page is never short of readable
categories. A deleted category (C<deleted_at> set) is never returned.

Only the anonymous list is cached: it is the one list every anonymous reader
shares, while a signed-in viewer's list depends on their grants. Each limit
is its own entry, under C<categories:list:anonymous:E<lt>limitE<gt>>, tagged
C<categories> and C<forum-index>, for C<cache_ttl_seconds>. The cached
elements are plain hashes of the category's columns, not rows: the shared
layer (GlifiStore, through L<GPForum::Service::Operations::TieredCache>)
holds JSON, and a row does not encode, so a list of rows never reached it
and every fill counted as a shared cache failure. The outbox's cache
invalidation handler (L<GPForum::Worker::Handler::CacheInvalidation>) and
the console's purge (L<GPForum::Service::Admin::Maintenance>) drop the list
through those tags. A single category (L</find_category>) is never cached.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> is the L<DBIx::Class> schema whose
C<Category> result source joins its C<space>. C<cache> is optional: any
object with C<get_or_set( $key, $code, { tags =E<gt> [...], ttl_seconds
=E<gt> $n } )>, such as L<GPForum::Service::Operations::LocalCache> or
L<GPForum::Service::Operations::TieredCache>; without one nothing is cached.
C<cache_ttl_seconds> is the anonymous list's lifetime (30 by default).

=head2 list_categories

Takes a hash reference with C<limit> and C<viewer>; the argument must be
passed but may be C<undef>, which reads as the default limit and an
anonymous viewer. The limit is bounded: absent, not made only of digits, or
below 1 gives 100, and above 200 gives 200. The viewer is a
L<GPForum::Service::Forum::Viewer>; none reads as anonymous.

Returns an array reference of the readable, non-deleted categories ordered
by position, title and category id. For an anonymous viewer when a cache is
set, the list comes from the cache (computed and stored on a miss) and its
elements are plain hashes of the category's columns; otherwise it is read
from the database and its elements are C<Category> rows. Its readers (the
view models, the home page, the sitemap) take either shape.

=head2 find_category

Takes a category id and an optional viewer: a
L<GPForum::Service::Forum::Viewer>, a bare user id (read as a non-member
with that id), or nothing for anonymous
(L<GPForum::Service::Forum::Viewer/from>). Returns the C<Category> row, with
its space's visibility as the extra column C<space_visibility>, when the
category exists, is not deleted and the viewer can read it and its space.
Otherwise, and for an undefined or empty id, returns C<undef>, so the caller
answers 404 and does not confirm that the category exists.

=head2 categories_resultset

Takes a row limit and an optional L<GPForum::Service::Forum::Viewer>
(nothing reads as anonymous). Returns, unexecuted, the resultset
L</list_categories> executes: non-deleted categories joined to their space,
restricted by L<GPForum::Service::Forum::Visibility/readable_condition>,
ordered by position, title and category id, with the limit as its row
count. The limit is used as given, not bounded. Public so that the query
plan evidence (L<GPForum::Command::QueryPlanEvidence>) EXPLAINs the query
that actually runs.

=head1 DIAGNOSTICS

Dies when the database does. Errors from the cache propagate from
L</list_categories>, which also dies when called with no argument, or with
a true argument that is not a hash reference. A viewer given to
L</list_categories> or L</categories_resultset> must be a
L<GPForum::Service::Forum::Viewer> object: only L</find_category> converts
a bare user id, and either method dies on one.

=head1 CONFIGURATION AND ENVIRONMENT

None directly. L<GPForum::Bootstrap::Forum> sets C<cache> to the
application cache and C<cache_ttl_seconds> from the configuration's
C<category_cache_ttl_seconds>.

=head1 DEPENDENCIES

L<Mojo::Base>, L<Const::Fast>, L<GPForum::Service::Forum::Viewer>,
L<GPForum::Service::Forum::Visibility>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The list's shape depends on whether it came from the cache: plain hashes
for a cached anonymous list, C<Category> rows otherwise. A change to a
category whose invalidation is missed leaves the cached anonymous list stale
for up to C<cache_ttl_seconds>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
