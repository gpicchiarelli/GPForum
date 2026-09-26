# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Discovery;

use strict;
use warnings;

use GPForum::Web::DiscoveryAccess;
use GPForum::Web::DiscoveryPayload;
use Mojo::Base 'Mojolicious::Controller', -signatures;

our $VERSION = '0.001';

sub robots ($self) {
    return GPForum::Web::DiscoveryAccess->new->render_document(
        $self,
        GPForum::Web::DiscoveryPayload->robots(
            policy => $self->gp_robots_policy,
        )
    );
}

sub sitemap ($self) {
    my $access = GPForum::Web::DiscoveryAccess->new;
    my $limit  = $access->sitemap_limit;

    return $access->render_document(
        $self,
        GPForum::Web::DiscoveryPayload->sitemap(
            builder    => $self->gp_sitemap_builder,
            categories =>
              $self->gp_category_reader->list_categories( { limit => $limit } ),
            presenter => $self->gp_discovery_view_model,
            threads   => $self->gp_thread_reader->list_public_threads(
                { limit => $limit }
            ),
        )
    );
}

sub feed ($self) {
    my $access = GPForum::Web::DiscoveryAccess->new;

    return $access->render_document(
        $self,
        GPForum::Web::DiscoveryPayload->feed(
            builder       => $self->gp_feed_builder,
            canonical_url => $self->gp_canonical_url,
            clock         => $self->gp_clock,
            page          => $self->gp_thread_reader->list_public_threads(
                { limit => $access->feed_limit( $self->param('limit') ) }
            ),
            presenter => $self->gp_discovery_view_model,
        )
    );
}

1;
