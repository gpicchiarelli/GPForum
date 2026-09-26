# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::TagCache;

use strict;
use warnings;

our $VERSION = '0.001';

# A cache that records the tags it is asked to invalidate.
sub new {
    my ($class) = @_;

    return bless { invalidated => [] }, $class;
}

sub invalidate_tag {
    my ( $self, $tag ) = @_;

    push @{ $self->{invalidated} }, $tag;
    return 1;
}

sub invalidated {
    my ($self) = @_;

    return $self->{invalidated};
}

1;
