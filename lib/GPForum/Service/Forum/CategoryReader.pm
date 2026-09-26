# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::CategoryReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

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
