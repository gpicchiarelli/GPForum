# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Discovery::SitemapBuilder;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use GPForum::Service::Discovery::VisibilityPolicy;

our $VERSION = '0.001';

has canonical_url => undef;
has visibility_policy =>
  sub { return GPForum::Service::Discovery::VisibilityPolicy->new; };

sub legal_entries ($self) {
    return [ map { { loc => $self->canonical_url->legal_url($_) } }
          qw(cookies privacy terms) ];
}

sub category_entries ( $self, $categories ) {
    return [
        map {
            {
                loc     => $self->canonical_url->category_url($_),
                lastmod => $_->{updated_at} || $_->{created_at},
            }
        } grep { $self->visibility_policy->is_public($_) } @{$categories}
    ];
}

sub thread_entries ( $self, $threads ) {
    return [
        map {
            {
                loc     => $self->canonical_url->thread_url($_),
                lastmod => $_->{last_activity_at} || $_->{created_at},
            }
        } grep { $self->visibility_policy->is_public($_) } @{$threads}
    ];
}

sub render_xml ( $self, $entries ) {
    my @urls = map { _url_xml($_) } @{$entries};

    return join "\n", '<?xml version="1.0" encoding="UTF-8"?>',
      '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
      @urls, '</urlset>', q{};
}

sub _url_xml ($entry) {
    my $loc     = _xml_escape( $entry->{loc} );
    my $lastmod = _xml_escape( $entry->{lastmod} || q{} );

    return
        '  <url><loc>'
      . $loc
      . '</loc><lastmod>'
      . $lastmod
      . '</lastmod></url>';
}

sub _xml_escape ($value) {
    $value =~ s/&/&amp;/gmsx;
    $value =~ s/</&lt;/gmsx;
    $value =~ s/>/&gt;/gmsx;
    $value =~ s/"/&quot;/gmsx;

    return $value;
}

1;
