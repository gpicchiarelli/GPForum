package GPForum::Test::SearchResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::SearchSearch;

our $VERSION = '0.001';

has created    => sub { return []; };
has deleted    => sub { return []; };
has last_attrs => undef;
has last_query => undef;
has rows       => sub { return []; };

sub find {
    my ( $self, $id ) = @_;

    for my $row ( @{ $self->rows } ) {
        return $row if _matches_id( $row, $id );
    }

    return;
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->last_query($query);
    $self->last_attrs($attrs);

    return GPForum::Test::SearchSearch->new(
        resultset => $self,
        rows      => $self->rows,
    );
}

sub update_or_create {
    my ( $self, $row ) = @_;

    push @{ $self->created }, $row;

    return $row;
}

sub _matches_id {
    my ( $row, $id ) = @_;

    return $row->get_column('thread_id') eq $id
      if defined $row->get_column('thread_id');
    return $row->get_column('post_id') eq $id
      if defined $row->get_column('post_id');

    return;
}

1;

