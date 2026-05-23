package GPForum::Test::ForumReadResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::ForumReadSearch;

our $VERSION = '0.001';

has last_attrs   => undef;
has last_query   => undef;
has rows         => sub { return []; };
has search_count => 0;

sub find {
    my ( $self, $id ) = @_;

    for my $row ( @{ $self->rows } ) {
        for my $column (qw(category_id thread_id post_id)) {
            my $value = $row->get_column($column);
            return $row if defined $value && $value eq $id;
        }
    }

    return;
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->search_count( $self->search_count + 1 );
    $self->last_query($query);
    $self->last_attrs($attrs);

    return GPForum::Test::ForumReadSearch->new( rows => $self->rows );
}

1;
