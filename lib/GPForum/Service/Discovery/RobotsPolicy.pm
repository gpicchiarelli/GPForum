# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Discovery::RobotsPolicy;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my @DEFAULT_DISALLOW => qw(
  /admin
  /login
  /logout
  /search
  /settings
);

has sitemap_url => undef;

sub rules ( $self, $extra_disallow ) {
    return [ @DEFAULT_DISALLOW, @{ $extra_disallow || [] } ];
}

sub render ( $self, $extra_disallow = undef ) {
    my @lines = ('User-agent: *');
    push @lines, map { 'Disallow: ' . $_ } @{ $self->rules($extra_disallow) };
    if ( $self->sitemap_url ) {
        push @lines, 'Sitemap: ' . $self->sitemap_url;
    }

    return join "\n", @lines, q{};
}

1;

__END__

=head1 NAME

GPForum::Service::Discovery::RobotsPolicy - Build the forum's robots.txt.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $robots = GPForum::Service::Discovery::RobotsPolicy->new(
        sitemap_url => $canonical_url->base_url . '/sitemap.xml',
    );
    my $text  = $robots->render;
    my $rules = $robots->rules( ['/drafts'] );

=head1 DESCRIPTION

One C<User-agent: *> group that keeps crawlers out of the pages that are
private or worthless to index (C</admin>, C</login>, C</logout>,
C</search>, C</settings>), plus any extra paths the caller passes, and a
C<Sitemap:> line when a sitemap URL is configured.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<sitemap_url> is optional; without it no
C<Sitemap:> line is written.

=head2 rules

Takes an array reference of extra paths to disallow, or C<undef>. Returns a
new array reference with the default paths followed by the extra ones.

=head2 render

Takes an optional array reference of extra paths. Returns the robots.txt
text: C<User-agent: *>, one C<Disallow:> line per rule, the C<Sitemap:>
line when set, lines joined by newlines and ending with one.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>.

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
