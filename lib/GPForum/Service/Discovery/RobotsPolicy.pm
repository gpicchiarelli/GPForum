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
