# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Discovery::VisibilityPolicy;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use GPForum::Service::Forum::Visibility;

our $VERSION = '0.001';

sub is_public ( $self, $resource ) {
    return
         _has_public_visibility($resource)
      && _has_visible_moderation($resource)
      && _is_not_removed($resource);
}

# The effective visibility of the levels the resource carries (ADR 0102): a
# thread page's thread brings its category and space, a sitemap row does not
# -- its list already kept only public categories and spaces.
sub _has_public_visibility ($resource) {
    my @levels = ( $resource->{visibility} );
    for my $level (qw(category_visibility space_visibility)) {
        if ( exists $resource->{$level} ) {
            push @levels, $resource->{$level};
        }
    }

    return GPForum::Service::Forum::Visibility->effective(@levels) eq 'public';
}

sub _has_visible_moderation ($resource) {
    return ( $resource->{moderation_state} || 'visible' ) eq 'visible';
}

sub _is_not_removed ($resource) {
    return !defined $resource->{deleted_at} && !defined $resource->{hidden_at};
}

1;
