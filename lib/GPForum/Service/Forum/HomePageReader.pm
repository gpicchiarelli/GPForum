package GPForum::Service::Forum::HomePageReader;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

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

sub home_page {
    my ( $self, $request ) = @_;

    my $category_limit =
      _bounded_limit( $request ? $request->{category_limit} : undef,
        $DEFAULT_CATEGORY_LIMIT, $MAX_CATEGORY_LIMIT, );
    my $thread_limit =
      _bounded_limit( $request ? $request->{thread_limit} : undef,
        $DEFAULT_THREAD_LIMIT, $MAX_THREAD_LIMIT, );
    my $after = $request ? $request->{after} : undef;

    my $categories =
      $self->_category_reader->list_categories( { limit => $category_limit } );
    my $threads = $self->_thread_reader->list_public_threads(
        {
            after => $after,
            limit => $thread_limit,
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

sub _category_reader {
    my ($self) = @_;

    return $self->category_reader
      if $self->category_reader;

    return GPForum::Service::Forum::CategoryReader->new(
        schema => $self->schema );
}

sub _thread_reader {
    my ($self) = @_;

    return $self->thread_reader
      if $self->thread_reader;

    return GPForum::Service::Forum::ThreadReader->new(
        schema => $self->schema );
}

sub _category {
    my ($row) = @_;

    return {
        category_id => _column( $row, 'category_id' ),
        description => _column( $row, 'description' ),
        position    => _column( $row, 'position' ),
        slug        => _column( $row, 'slug' ),
        title       => _column( $row, 'title' ),
        visibility  => _column( $row, 'visibility' ),
    };
}

sub _thread {
    my ($row) = @_;

    return {
        author_user_id   => _column( $row, 'author_user_id' ),
        category_id      => _column( $row, 'category_id' ),
        created_at       => _column( $row, 'created_at' ),
        deleted_at       => _column( $row, 'deleted_at' ),
        hidden_at        => _column( $row, 'hidden_at' ),
        last_activity_at => _column( $row, 'last_activity_at' ),
        moderation_state => _column( $row, 'moderation_state' ),
        pinned           => _column( $row, 'pinned' ),
        safe_excerpt     => _column( $row, 'safe_excerpt' ),
        slug             => _column( $row, 'slug' ),
        thread_id        => _column( $row, 'thread_id' ),
        title            => _column( $row, 'title' ),
        visibility       => _column( $row, 'visibility' ),
    };
}

sub _column {
    my ( $row, $name ) = @_;

    return $row->get_column($name)
      if ref $row && $row->can('get_column');

    return $row->{$name}
      if ref $row eq 'HASH';

    return;
}

sub _bounded_limit {
    my ( $requested, $default, $max ) = @_;

    return $default if !defined $requested;
    return $max     if $requested > $max;
    return int $requested;
}

1;
