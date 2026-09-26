# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Bootstrap::Discovery;

use strict;
use warnings;
use feature 'signatures';

use GPForum::Service::Discovery::CanonicalUrl;
use GPForum::Service::Discovery::FeedBuilder;
use GPForum::Service::Discovery::MetadataBuilder;
use GPForum::Service::Discovery::RobotsPolicy;
use GPForum::Service::Discovery::SitemapBuilder;

our $VERSION = '0.001';

sub register {
    my ( undef, %input ) = @_;

    my $application = $input{application};
    my $config      = $input{config};

    $application->helper(
        gp_canonical_url => sub {
            return GPForum::Service::Discovery::CanonicalUrl->new(
                base_url => $config->public_base_url );
        }
    );
    $application->helper(
        gp_feed_builder => sub {
            my ($controller) = @_;

            return GPForum::Service::Discovery::FeedBuilder->new(
                canonical_url => $controller->gp_canonical_url );
        }
    );
    $application->helper(
        gp_metadata_builder => sub {
            my ($controller) = @_;

            return GPForum::Service::Discovery::MetadataBuilder->new(
                canonical_url => $controller->gp_canonical_url );
        }
    );
    $application->helper(
        gp_sitemap_builder => sub {
            my ($controller) = @_;

            return GPForum::Service::Discovery::SitemapBuilder->new(
                canonical_url => $controller->gp_canonical_url );
        }
    );
    $application->helper(
        gp_robots_policy => sub {
            my ($controller) = @_;

            return GPForum::Service::Discovery::RobotsPolicy->new(
                sitemap_url => $controller->gp_canonical_url->base_url
                  . '/sitemap.xml', );
        }
    );

    return;
}

1;
