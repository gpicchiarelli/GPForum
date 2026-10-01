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

__END__

=head1 NAME

GPForum::Service::Discovery::VisibilityPolicy - Whether a resource may appear in the sitemap and the public feed.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $policy = GPForum::Service::Discovery::VisibilityPolicy->new;
    my @public = grep { $policy->is_public($_) } @{$resources};

=head1 DESCRIPTION

The test the discovery builders apply before showing anything to crawlers
and feed readers. A resource is public when its effective visibility is
public, its moderation state is C<visible> (or absent), and it is neither
deleted nor hidden.

The effective visibility is the most restrictive of the resource's own
C<visibility> and, when the hash carries them, its C<category_visibility>
and C<space_visibility> (ADR 0102): a thread page's thread brings its
category and space, while a sitemap row does not, since its list already
kept only public categories and spaces.

=head1 SUBROUTINES/METHODS

=head2 is_public

Takes a resource hash reference (C<visibility>, and optionally
C<category_visibility>, C<space_visibility>, C<moderation_state>,
C<deleted_at> and C<hidden_at>). Returns true when it may be published and
false otherwise; an unknown visibility counts as private.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Forum::Visibility>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
