package GPForum::Test::ProjectionOffsetResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::ProjectionOffsetRow;

our $VERSION = '0.001';

has rows   => sub { return {}; };
has writes => sub { return []; };

sub update_or_create {
    my ( $self, $row ) = @_;

    push @{ $self->writes }, $row;
    $self->rows->{ $row->{projection_name} } =
      GPForum::Test::ProjectionOffsetRow->new( data => $row );

    return $self->rows->{ $row->{projection_name} };
}

sub find {
    my ( $self, $projection_name ) = @_;

    return $self->rows->{$projection_name};
}

1;
