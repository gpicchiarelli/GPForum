# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::ViewModel::Discovery::Presenter;

use strict;
use warnings;

use Mojo::Base 'GPForum::ViewModel::Base', -signatures;

our $VERSION = '0.001';

sub resources ( $self, $rows ) {
    return [ map { $self->resource($_) } @{ $rows || [] } ];
}

sub resource ( $self, $row ) {
    my $resource = {};
    if ( ref $row eq 'HASH' ) {
        $resource = { %{$row} };
    }
    elsif ( $row && $row->can('columns') ) {
        $resource = { map { $_ => $self->column( $row, $_ ) } $row->columns };
    }

    my $resource_id =
         $resource->{thread_id}
      || $resource->{category_id}
      || $resource->{post_id}
      || $resource->{slug};
    $resource->{ui} =
      { heading_id => $self->stable_id( 'discovery', $resource_id, 'heading' ),
      };

    return $resource;
}

1;
