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

__END__

=head1 NAME

GPForum::Service::Discovery::SitemapBuilder - Sitemap entries for public pages and their XML.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $builder = GPForum::Service::Discovery::SitemapBuilder->new(
        canonical_url => $canonical_url,
    );

    my @entries = (
        @{ $builder->legal_entries },
        @{ $builder->category_entries($categories) },
        @{ $builder->thread_entries($threads) },
    );
    my $xml = $builder->render_xml( \@entries );

=head1 DESCRIPTION

Builds the entries of C</sitemap.xml> and renders them. Categories and
threads appear only when L<GPForum::Service::Discovery::VisibilityPolicy>
calls them public; the cookie, privacy and terms pages always appear. Every
location comes from the C<canonical_url> object (a
L<GPForum::Service::Discovery::CanonicalUrl>).

=head1 SUBROUTINES/METHODS

=head2 legal_entries

Returns an array reference of three entries, C<< { loc => ... } >>, for the
cookies, privacy and terms pages.

=head2 category_entries

Takes an array reference of category hashes. Returns an array reference of
C<< { loc, lastmod } >> entries for the public ones, with C<lastmod> set to
C<updated_at>, or C<created_at>.

=head2 thread_entries

Takes an array reference of thread hashes. Returns an array reference of
C<< { loc, lastmod } >> entries for the public ones, with C<lastmod> set to
C<last_activity_at>, or C<created_at>.

=head2 render_xml

Takes an array reference of entries. Returns the sitemap XML as a string, a
C<urlset> with one C<url> element per entry; C<loc> and C<lastmod> are
escaped, and a missing C<lastmod> renders empty.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None here: C<canonical_url> carries the public base URL.

=head1 DEPENDENCIES

L<GPForum::Service::Discovery::VisibilityPolicy>,
L<GPForum::Service::Discovery::CanonicalUrl>.

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
