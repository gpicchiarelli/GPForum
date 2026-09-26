# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Test::Mojo;
use Test::More;

use lib 'lib';

use GPForum::Bootstrap::Discovery;
use GPForum::Config;
use Mojolicious;

our $VERSION = '0.001';

can_ok( 'GPForum::Bootstrap::Discovery', 'register' );

my $config =
  GPForum::Config->new( public_base_url => 'https://forum.example.test', );
my $application = Mojolicious->new;
$application->secrets( ['bootstrap-discovery-test'] );

GPForum::Bootstrap::Discovery->register(
    application => $application,
    config      => $config,
);

my $controller = $application->build_controller;

isa_ok(
    $controller->gp_canonical_url,
    'GPForum::Service::Discovery::CanonicalUrl',
    'discovery bootstrap registers canonical URL helper'
);
isa_ok(
    $controller->gp_feed_builder,
    'GPForum::Service::Discovery::FeedBuilder',
    'discovery bootstrap registers feed builder helper'
);
isa_ok(
    $controller->gp_metadata_builder,
    'GPForum::Service::Discovery::MetadataBuilder',
    'discovery bootstrap registers metadata builder helper'
);
isa_ok(
    $controller->gp_sitemap_builder,
    'GPForum::Service::Discovery::SitemapBuilder',
    'discovery bootstrap registers sitemap builder helper'
);
isa_ok(
    $controller->gp_robots_policy,
    'GPForum::Service::Discovery::RobotsPolicy',
    'discovery bootstrap registers robots policy helper'
);

is(
    $controller->gp_canonical_url->thread_url(
        {
            thread_id => 'thread-1',
            slug      => 'welcome',
        }
    ),
    'https://forum.example.test/t/thread-1/welcome',
    'canonical helper uses configured public base URL'
);

like(
    $controller->gp_robots_policy->render,
    qr{^Sitemap:\s+https://forum[.]example[.]test/sitemap[.]xml$}ms,
    'robots policy helper uses configured sitemap URL'
);

$application->routes->get('/__discovery/robots')->to(
    cb => sub {
        my ($controller) = @_;

        return $controller->render(
            text => $controller->gp_robots_policy->render );
    }
);

Test::Mojo->new($application)
  ->get_ok('/__discovery/robots')
  ->status_is(200)
  ->content_like(qr{User-agent:\s+[*]}ms)
  ->content_like(qr{Sitemap:\s+https://forum[.]example[.]test/sitemap[.]xml}ms);

done_testing();

1;
