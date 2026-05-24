package GPForum::Service::Forum::CategoryReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT             => 100;
const my $MAX_LIMIT                 => 200;
const my $DEFAULT_CACHE_TTL_SECONDS => 30;

has cache             => undef;
has cache_ttl_seconds => sub { return $DEFAULT_CACHE_TTL_SECONDS; };
has schema            => undef;

sub list_categories {
    my ( $self, $request ) = @_;

    my $limit = _bounded_limit( $request ? $request->{limit} : undef );

    return $self->_cached_categories($limit)
      if $self->cache;

    return $self->_list_categories($limit);
}

sub find_category {
    my ( $self, $category_id ) = @_;

    return if !defined $category_id || !length $category_id;

    my $row = $self->schema->resultset('Category')->find($category_id);

    return if !$row;
    return if defined $row->get_column('deleted_at');

    return $row;
}

sub _cached_categories {
    my ( $self, $limit ) = @_;

    my $key = join q{:}, 'categories', 'list', $limit;

    return $self->cache->get_or_set(
        $key,
        sub {
            return $self->_list_categories($limit);
        },
        {
            tags        => [ 'categories', 'forum-index' ],
            ttl_seconds => $self->cache_ttl_seconds,
        }
    );
}

sub _list_categories {
    my ( $self, $limit ) = @_;

    my $search = $self->schema->resultset('Category')->search(
        { deleted_at => undef },
        {
            order_by => [
                { -asc => 'position' },
                { -asc => 'title' },
                { -asc => 'category_id' },
            ],
            rows => $limit,
        }
    );

    return [ _rows($search) ];
}

sub _bounded_limit {
    my ($requested) = @_;

    return $DEFAULT_LIMIT if !defined $requested;
    return $DEFAULT_LIMIT if $requested !~ /\A [[:digit:]]+ \z/msx;
    return $DEFAULT_LIMIT if $requested < 1;
    return $MAX_LIMIT     if $requested > $MAX_LIMIT;

    return int $requested;
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
