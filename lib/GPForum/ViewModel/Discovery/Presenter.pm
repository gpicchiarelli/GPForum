package GPForum::ViewModel::Discovery::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base';

our $VERSION = '0.001';

sub resources {
    my ( $self, $rows ) = @_;

    return [ map { $self->resource($_) } @{ $rows || [] } ];
}

sub resource {
    my ( $self, $row ) = @_;

    return { %{$row} } if ref $row eq 'HASH';
    return {}          if !$row || !$row->can('columns');

    return { map { $_ => $self->column( $row, $_ ) } $row->columns };
}

1;
