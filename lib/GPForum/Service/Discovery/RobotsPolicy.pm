package GPForum::Service::Discovery::RobotsPolicy;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my @DEFAULT_DISALLOW => qw(
  /admin
  /login
  /logout
  /search
  /settings
);

has sitemap_url => undef;

sub rules {
    my ( $self, $extra_disallow ) = @_;

    return [ @DEFAULT_DISALLOW, @{ $extra_disallow || [] } ];
}

sub render {
    my ( $self, $extra_disallow ) = @_;

    my @lines = ('User-agent: *');
    push @lines, map { 'Disallow: ' . $_ } @{ $self->rules($extra_disallow) };
    if ( $self->sitemap_url ) {
        push @lines, 'Sitemap: ' . $self->sitemap_url;
    }

    return join "\n", @lines, q{};
}

1;
