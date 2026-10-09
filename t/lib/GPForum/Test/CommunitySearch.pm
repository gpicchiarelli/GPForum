# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::CommunitySearch;

use Mojo::Base 'GPForum::Test::SearchResult';
use v5.40;

our $VERSION = '0.001';

has query     => undef;
has resultset => undef;

sub delete_rows {
    my ($self) = @_;

    if ( !$self->resultset ) {
        return 0;
    }

    return $self->resultset->delete_matching( $self->query || {} );
}

BEGIN {
    *delete = \&delete_rows;
}

1;
