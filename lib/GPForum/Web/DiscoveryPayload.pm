# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::DiscoveryPayload;

use strict;
use warnings;
use feature 'signatures';

use Const::Fast;

our $VERSION = '0.001';

const my $HTTP_OK              => 200;
const my $ATOM_CONTENT_TYPE    => 'application/atom+xml; charset=utf-8';
const my $SITEMAP_CONTENT_TYPE => 'application/xml; charset=utf-8';
const my $TEXT_CONTENT_TYPE    => 'text/plain; charset=utf-8';
const my $PUBLIC_FEED_TITLE    => 'GPForum public discussions';
const my $PUBLIC_FEED_PATH     => '/feed.atom';

sub robots ( $, %input ) {
    return {
        content_type => $TEXT_CONTENT_TYPE,
        data         => $input{policy}->render,
        format       => 'txt',
        status       => $HTTP_OK,
    };
}

sub sitemap ( $, %input ) {
    my $builder = $input{builder};
    my @entries = (
        @{ $builder->legal_entries },
        @{
            $builder->category_entries(
                $input{presenter}->resources( $input{categories} )
            )
        },
        @{
            $builder->thread_entries(
                $input{presenter}->resources( _items( $input{threads} ) )
            )
        },
    );

    return {
        content_type => $SITEMAP_CONTENT_TYPE,
        data         => $builder->render_xml( \@entries ),
        format       => 'xml',
        status       => $HTTP_OK,
    };
}

sub feed ( $, %input ) {
    my $builder = $input{builder};
    my $items   = $builder->thread_items(
        $input{presenter}->resources( _items( $input{page} ) ) );
    my $url = $input{canonical_url}->base_url . $PUBLIC_FEED_PATH;

    return {
        content_type => $ATOM_CONTENT_TYPE,
        data         => $builder->render_atom(
            {
                id      => $url,
                title   => $PUBLIC_FEED_TITLE,
                url     => $url,
                updated => _updated( $items, $input{clock} ),
                items   => $items,
            }
        ),
        format => 'atom',
        status => $HTTP_OK,
    };
}

sub _items ($value) {
    return []              if !defined $value;
    return $value->{items} if ref $value eq 'HASH';

    return $value;
}

sub _updated ( $items, $clock ) {
    return $items->[0]{updated} if @{$items};

    return $clock->now_iso8601;
}

1;

__END__

=head1 NAME

GPForum::Web::DiscoveryPayload - The robots.txt, sitemap and Atom feed responses as render payloads.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $payload = GPForum::Web::DiscoveryPayload->feed(
        builder       => $feed_builder,
        canonical_url => $canonical_url,
        clock         => $clock,
        page          => $thread_reader->list_public_threads( { limit => 50 } ),
        presenter     => $discovery_presenter,
    );
    # { content_type => 'application/atom+xml; charset=utf-8',
    #   data => '<?xml ...', format => 'atom', status => 200 }

=head1 DESCRIPTION

Builds what L<GPForum::Controller::Discovery> hands to
L<GPForum::Web::DiscoveryAccess> for the three discovery documents. Each
class method takes named arguments, asks the matching builder for the
document's text, and returns a hash reference with C<content_type>, C<data>,
C<format> and C<status> (always 200). The controller supplies the readers'
rows, the presenter turns them into plain hashes, and the builders keep only
what is public. A thread list may be given as a page hash, whose C<items>
are used, or as an array reference.

=head1 SUBROUTINES/METHODS

=head2 robots

Class method. Takes C<policy>, a L<GPForum::Service::Discovery::RobotsPolicy>.
Returns the payload with the policy's rendered text as
C<text/plain; charset=utf-8>, format C<txt>.

=head2 sitemap

Class method. Takes C<builder> (a
L<GPForum::Service::Discovery::SitemapBuilder>), C<presenter>,
C<categories> (an array reference of category rows) and C<threads> (a page
hash or an array reference of thread rows). Returns the payload with the
sitemap XML of the legal pages, then the categories, then the threads, as
C<application/xml; charset=utf-8>, format C<xml>.

=head2 feed

Class method. Takes C<builder> (a
L<GPForum::Service::Discovery::FeedBuilder>), C<presenter>,
C<canonical_url> (a L<GPForum::Service::Discovery::CanonicalUrl>), C<clock>
and C<page> (a page hash or an array reference of thread rows). Returns the
payload with an Atom document titled C<GPForum public discussions>, whose id
and link are the base URL followed by C</feed.atom> and whose C<updated> is
the first item's, or the clock's current time when there are no items; as
C<application/atom+xml; charset=utf-8>, format C<atom>.

=head1 DIAGNOSTICS

None of its own. Errors from the builders, the presenter and the policy
propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None. The feed's base URL comes from C<canonical_url>.

=head1 DEPENDENCIES

L<Const::Fast>. It loads no GPForum module; the objects passed in are
normally L<GPForum::Service::Discovery::RobotsPolicy>,
L<GPForum::Service::Discovery::SitemapBuilder>,
L<GPForum::Service::Discovery::FeedBuilder>,
L<GPForum::Service::Discovery::CanonicalUrl> and
L<GPForum::ViewModel::Discovery::Presenter>.

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
