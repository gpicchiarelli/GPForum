package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';

use GPForum::Service::Discovery::CanonicalUrl;
use GPForum::Service::Discovery::FeedBuilder;
use GPForum::Service::Discovery::RobotsPolicy;
use GPForum::Service::Discovery::SitemapBuilder;
use GPForum::ViewModel::Discovery::Presenter;
use GPForum::Web::DiscoveryPayload;
use GPForum::Web::OperationsPayload;

our $VERSION = '0.001';

my $metrics = { status => 'ok', counters => { requests => 3 } };
is_deeply( GPForum::Web::OperationsPayload->metrics( snapshot => $metrics ),
    $metrics, 'operations metrics payload preserves collector snapshot' );
is_deeply( GPForum::Web::OperationsPayload->metrics,
    {}, 'operations metrics payload handles missing snapshot' );

my $canonical =
  GPForum::Service::Discovery::CanonicalUrl->new(
    base_url => 'https://forum.gp' );
my $presenter = GPForum::ViewModel::Discovery::Presenter->new;
my $clock     = GPForum::Test::DiscoveryPayloadClock->new;

my $robots = GPForum::Web::DiscoveryPayload->robots(
    policy => GPForum::Service::Discovery::RobotsPolicy->new(
        sitemap_url => 'https://forum.gp/sitemap.xml',
    ),
);
is(
    $robots->{content_type},
    'text/plain; charset=utf-8',
    'robots payload declares text content type'
);
is( $robots->{format}, 'txt', 'robots payload declares txt format' );
is( $robots->{status}, 200,   'robots payload declares HTTP 200 status' );
like(
    $robots->{data},
    qr/User-agent: [ ] [*]/msx,
    'robots payload renders policy document'
);

my $visible_thread = {
    thread_id        => 'thread-1',
    slug             => 'welcome',
    title            => 'Welcome',
    visibility       => 'public',
    moderation_state => 'visible',
    created_at       => '2026-05-28T08:00:00Z',
    last_activity_at => '2026-05-28T09:00:00Z',
    safe_excerpt     => 'First public post',
};
my $hidden_thread = {
    %{$visible_thread},
    thread_id        => 'thread-hidden',
    slug             => 'hidden',
    title            => 'Hidden',
    moderation_state => 'hidden',
    safe_excerpt     => 'hidden text must not leak',
};
my $category = {
    category_id => 'category-1',
    slug        => 'general',
    visibility  => 'public',
    created_at  => '2026-05-28T07:00:00Z',
};

my $sitemap = GPForum::Web::DiscoveryPayload->sitemap(
    builder => GPForum::Service::Discovery::SitemapBuilder->new(
        canonical_url => $canonical,
    ),
    categories => [$category],
    presenter  => $presenter,
    threads    => { items => [ $visible_thread, $hidden_thread ] },
);
is(
    $sitemap->{content_type},
    'application/xml; charset=utf-8',
    'sitemap payload declares XML content type'
);
is( $sitemap->{format}, 'xml', 'sitemap payload declares xml format' );
like( $sitemap->{data}, qr/<urlset/msx,
    'sitemap payload renders urlset document' );
like( $sitemap->{data}, qr{/c/general}msx,
    'sitemap payload includes public category' );
like( $sitemap->{data}, qr{/t/thread-1/welcome}msx,
    'sitemap payload includes public thread' );
like( $sitemap->{data}, qr{/legal/terms}msx,
    'sitemap payload includes legal terms' );
unlike(
    $sitemap->{data},
    qr/thread-hidden|hidden [ ] text/msx,
    'sitemap payload excludes hidden thread'
);

my $feed = GPForum::Web::DiscoveryPayload->feed(
    builder => GPForum::Service::Discovery::FeedBuilder->new(
        canonical_url => $canonical,
    ),
    canonical_url => $canonical,
    clock         => $clock,
    page          => { items => [ $visible_thread, $hidden_thread ] },
    presenter     => $presenter,
);
is(
    $feed->{content_type},
    'application/atom+xml; charset=utf-8',
    'feed payload declares Atom content type'
);
is( $feed->{format}, 'atom', 'feed payload declares atom format' );
like(
    $feed->{data},
    qr/<title>GPForum [ ] public [ ] discussions<\/title>/msx,
    'feed payload renders canonical public title'
);
like(
    $feed->{data},
    qr/First [ ] public [ ] post/msx,
    'feed payload includes public safe excerpt'
);
unlike(
    $feed->{data},
    qr/hidden [ ] text [ ] must [ ] not [ ] leak/msx,
    'feed payload excludes hidden excerpts'
);

my $empty_feed = GPForum::Web::DiscoveryPayload->feed(
    builder => GPForum::Service::Discovery::FeedBuilder->new(
        canonical_url => $canonical,
    ),
    canonical_url => $canonical,
    clock         => $clock,
    page          => { items => [] },
    presenter     => $presenter,
);
like(
    $empty_feed->{data},
    qr/<updated>2026-05-28T12:00:00Z<\/updated>/msx,
    'empty feed payload uses clock fallback timestamp'
);

done_testing();

package GPForum::Test::DiscoveryPayloadClock;

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub now_iso8601 {
    return '2026-05-28T12:00:00Z';
}

1;
