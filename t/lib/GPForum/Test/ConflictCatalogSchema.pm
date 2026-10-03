# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ConflictCatalogSchema;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A schema whose storage answers as PostgreSQL and whose catalog lists one
# index family: the constraint and the indexes its partitions attached to it.
# Any other constraint is its own family of one.
# What GPForum::X::Conflict->on reads to match a partition's index.
has family => sub { return []; };

sub storage ($self) {
    return $self;
}

sub dbh ($self) {
    return $self;
}

sub get_info ( $, $ ) {
    return 'PostgreSQL';
}

sub selectcol_arrayref ( $self, $sql, $attributes, $constraint ) {
    my $family = $self->family;
    if ( @{$family} && $family->[0] eq $constraint ) {
        return $family;
    }

    return [$constraint];
}

1;
