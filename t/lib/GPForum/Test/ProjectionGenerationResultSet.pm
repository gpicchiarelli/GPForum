package GPForum::Test::ProjectionGenerationResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::ProjectionGenerationRow;
use GPForum::Test::ProjectionGenerationSearch;

our $VERSION = '0.001';

has rows       => sub { return {}; };
has created    => sub { return []; };
has last_query => sub { return {}; };

sub create {
    my ( $self, $row ) = @_;

    my $generation =
      GPForum::Test::ProjectionGenerationRow->new( data => $row );
    $self->rows->{ $row->{generation_id} } = $generation;
    push @{ $self->created }, $row;

    return $generation;
}

sub find {
    my ( $self, $generation_id ) = @_;

    return $self->rows->{$generation_id};
}

sub search {
    my ( $self, $query ) = @_;

    my @active = grep {
             $_->get_column('projection_name') eq $query->{projection_name}
          && $_->get_column('is_active') == $query->{is_active}
    } values %{ $self->rows };

    $self->last_query($query);

    return GPForum::Test::ProjectionGenerationSearch->new( rows => \@active );
}

1;
