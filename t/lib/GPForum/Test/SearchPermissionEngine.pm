# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SearchPermissionEngine;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has denied_entities => sub { return {}; };
has visibility      => sub { return ['public']; };

sub search_visibility_for {
    my ( $self, $actor, $options ) = @_;

    return @{ $self->visibility };
}

# The real engine expresses its rule as SQL so the database applies it before
# LIMIT. A double without this method sends Searcher down its compatibility
# path, and the unit tier would keep exercising the shape that let a member's
# result page come back empty.
sub search_condition {
    my ( $self, $actor ) = @_;

    return { 'me.visibility' => { -in => [ @{ $self->visibility } ] } };
}

sub permits {
    my ( $self, @arguments ) = @_;

    my $resource = $arguments[2];
    return !$self->denied_entities->{ $resource->{entity_id} };
}

1;
