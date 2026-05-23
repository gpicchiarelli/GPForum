package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';

use GPForum::Service::Discovery::CanonicalUrl;
use GPForum::Service::Discovery::FeedBuilder;
use GPForum::Service::Discovery::MetadataBuilder;
use GPForum::Service::Discovery::RobotsPolicy;
use GPForum::Service::Discovery::SitemapBuilder;
use GPForum::Service::Discovery::VisibilityPolicy;

our $VERSION = '0.001';

const my $EXPECTED_TESTS       => 32;
const my $VISIBLE_THREAD_COUNT => 1;
const my $ROBOT_RULE_COUNT     => 6;

plan tests => $EXPECTED_TESTS;

my $canonical =
  GPForum::Service::Discovery::CanonicalUrl->new(
    base_url => 'https://forum.gp' );

is(
    $canonical->space_url( { slug => 'general' } ),
    'https://forum.gp/spaces/general',
    'canonical space url is stable'
);
is(
    $canonical->category_url( { slug => 'announcements' } ),
    'https://forum.gp/c/announcements',
    'canonical category url is stable'
);
is(
    $canonical->thread_url(
        {
            thread_id => 'thread-1',
            slug      => 'welcome',
        }
    ),
    'https://forum.gp/t/thread-1/welcome',
    'canonical thread url includes id and slug'
);
is(
    $canonical->thread_url( { thread_id => 'thread-2' } ),
    'https://forum.gp/t/thread-2/untitled',
    'canonical thread url handles missing slug'
);
is_deeply(
    $canonical->legacy_redirect(
        {
            canonical_url => '/old/topic/42',
            native_path   => '/t/thread-42/welcome',
        }
    ),
    {
        from   => '/old/topic/42',
        to     => 'https://forum.gp/t/thread-42/welcome',
        status => 301,
    },
    'legacy redirect preserves safe canonical path'
);

my $metadata =
  GPForum::Service::Discovery::MetadataBuilder->new(
    canonical_url => $canonical );
my $visible_thread = {
    thread_id        => 'thread-1',
    slug             => 'welcome',
    title            => 'Welcome',
    visibility       => 'public',
    moderation_state => 'visible',
    last_activity_at => '2026-05-23T12:00:00Z',
    safe_excerpt     => '<b>Hello</b> safe public world',
};
my $thread_metadata = $metadata->thread_metadata(
    $visible_thread,
    {
        safe_text => '<p>Hello safe public world</p>',
    }
);
is( $thread_metadata->{title}, 'Welcome', 'metadata exposes safe title' );
is(
    $thread_metadata->{description},
    'Hello safe public world',
    'metadata strips html from description'
);
is(
    $thread_metadata->{canonical},
    'https://forum.gp/t/thread-1/welcome',
    'metadata includes canonical url'
);
is( $thread_metadata->{robots}, 'index,follow',
    'public metadata is indexable' );

my $private_metadata = $metadata->thread_metadata(
    {
        %{$visible_thread}, visibility => 'private',
    },
    {
        safe_text => 'secret',
    }
);
is( $private_metadata->{robots},
    'noindex,nofollow', 'private thread metadata is noindex' );
ok(
    !exists $private_metadata->{description},
    'private thread metadata does not leak description'
);

my $visibility_policy = GPForum::Service::Discovery::VisibilityPolicy->new;
ok(
    $visibility_policy->is_public($visible_thread),
    'visibility policy allows visible public resources'
);
ok(
    !$visibility_policy->is_public(
        { %{$visible_thread}, hidden_at => 'now' }
    ),
    'visibility policy blocks hidden resources'
);
ok(
    !$visibility_policy->is_public(
        { %{$visible_thread}, deleted_at => 'now' }
    ),
    'visibility policy blocks deleted resources'
);

my $robots = GPForum::Service::Discovery::RobotsPolicy->new(
    sitemap_url => 'https://forum.gp/sitemap.xml', );
my $rules = $robots->rules( ['/preview'] );
is( scalar @{$rules},
    $ROBOT_RULE_COUNT, 'robots policy combines default rules' );
ok( grep { $_ eq '/admin' } @{$rules}, 'robots policy disallows admin routes' );
ok(
    grep { $_ eq '/search' } @{$rules},
    'robots policy disallows search routes'
);
ok( grep { $_ eq '/preview' } @{$rules}, 'robots policy accepts extra rules' );
my $robots_text = $robots->render( ['/preview'] );
like(
    $robots_text,
    qr/User-agent: [ ] [*]/msx,
    'robots text declares user agent'
);
like(
    $robots_text,
    qr/Disallow: [ ] \/admin/msx,
    'robots text renders admin rule'
);
like(
    $robots_text,
    qr/Sitemap: [ ] https:\/\/forum[.]gp\/sitemap[.]xml/msx,
    'robots text renders sitemap location'
);

my $sitemap =
  GPForum::Service::Discovery::SitemapBuilder->new(
    canonical_url => $canonical );
my $threads = [
    $visible_thread,
    {
        %{$visible_thread},
        thread_id        => 'thread-2',
        slug             => 'hidden',
        moderation_state => 'hidden',
    },
    {
        %{$visible_thread},
        thread_id  => 'thread-3',
        slug       => 'private',
        visibility => 'private',
    },
];
my $thread_entries = $sitemap->thread_entries($threads);
is( scalar @{$thread_entries},
    $VISIBLE_THREAD_COUNT, 'sitemap excludes hidden and private threads' );
is(
    $thread_entries->[0]{loc},
    'https://forum.gp/t/thread-1/welcome',
    'sitemap entry includes canonical location'
);
is( $thread_entries->[0]{lastmod},
    '2026-05-23T12:00:00Z', 'sitemap entry includes last modification time' );
my $category_entries = $sitemap->category_entries(
    [
        {
            slug       => 'public',
            visibility => 'public',
            created_at => '2026-05-23T12:00:00Z',
        },
        {
            slug       => 'staff',
            visibility => 'private',
            created_at => '2026-05-23T12:00:00Z',
        },
    ]
);
is( scalar @{$category_entries},
    $VISIBLE_THREAD_COUNT, 'sitemap excludes private categories' );
my $xml = $sitemap->render_xml($thread_entries);
like( $xml, qr/<urlset/msx, 'sitemap xml renders urlset' );
like(
    $xml,
    qr/<loc>https:\/\/forum[.]gp\/t\/thread-1\/welcome<\/loc>/msx,
    'sitemap xml renders location'
);

my $feed =
  GPForum::Service::Discovery::FeedBuilder->new( canonical_url => $canonical );
my $items = $feed->thread_items($threads);
is( scalar @{$items},
    $VISIBLE_THREAD_COUNT, 'feed excludes hidden and private threads' );
is( $items->[0]{id},    'thread-1', 'feed item stores id' );
is( $items->[0]{title}, 'Welcome',  'feed item stores title' );
is(
    $items->[0]{summary},
    'Hello safe public world',
    'feed item exposes safe excerpt only'
);
ok( !defined $items->[0]{full_body},
    'feed does not expose full body by default' );

1;
