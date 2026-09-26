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
