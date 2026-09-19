package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';

use GPForum::Service::Forum::BodyRenderer;
use GPForum::ViewModel::Forum::Rows;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 16;

plan tests => $EXPECTED_TESTS;

my $renderer = GPForum::Service::Forum::BodyRenderer->new;

is( $renderer->render_safe(undef), q{}, 'undef source renders empty' );
is( $renderer->render_safe(q{}),   q{}, 'empty source renders empty' );
is(
    $renderer->render_safe('Hello <forum> & welcome'),
    '<p>Hello &lt;forum&gt; &amp; welcome</p>',
    'plain text is escaped and wrapped'
);

my $xss = $renderer->render_safe(
    "<script>alert(1)</script>\n[bad](javascript:alert(1))");
unlike( $xss, qr/<script/imsx, 'script tags are not emitted' );
like( $xss, qr/&lt;script&gt;/msx, 'script tags are escaped as text' );
unlike( $xss, qr/<a\b/imsx, 'javascript links are not turned into anchors' );

my $fenced =
  $renderer->render_safe("intro\n```\n<script>alert(1)</script>\n```\nafter");
is(
    $fenced,
"<p>intro</p>\n<pre><code>&lt;script&gt;alert(1)&lt;/script&gt;</code></pre>\n<p>after</p>",
    'fenced code preserves escaped source'
);
unlike( $fenced, qr{<pre><code>.*<script}imsx,
    'fenced code does not contain a live script tag' );

my $quote = $renderer->render_safe("> quoted <em>html</em>\n> **bold**");
is(
    $quote,
'<blockquote><p>quoted &lt;em&gt;html&lt;/em&gt;<br><strong>bold</strong></p></blockquote>',
    'quotes wrap escaped lines and still apply emphasis'
);

is(
    $renderer->render_safe('See [docs](https://example.com/a?x=1&y=2).'),
'<p>See <a href="https://example.com/a?x=1&amp;y=2" rel="nofollow noopener noreferrer">docs</a>.</p>',
    'http links are allowed after escaping'
);
is(
    $renderer->render_safe('*italic* and **bold**'),
    '<p><em>italic</em> and <strong>bold</strong></p>',
    'emphasis markers become em and strong'
);

my $mention = q{@} . 'alice';
my $leftover =
  $renderer->render_safe("![logo](https://example.com/x.png) and $mention");
unlike( $leftover, qr/<img\b/imsx,          'inline images are not rendered' );
unlike( $leftover, qr{href="[^"]*alice}msx, 'mentions are not linked' );
ok( index( $leftover, $mention ) >= 0, 'mentions remain literal text' );

my $rows = GPForum::ViewModel::Forum::Rows->new;
my $post = $rows->post(
    {
        body_source => '**Safe** <script>alert(1)</script>',
        post_id     => 'post-9',
        thread_id   => 'thread-1',
    }
);
is(
    $post->{body},
    '<p><strong>Safe</strong> &lt;script&gt;alert(1)&lt;/script&gt;</p>',
    'post presenter renders markdown source through the body renderer'
);
unlike( $post->{body}, qr/<script/imsx,
    'post presenter does not emit script tags from source' );

1;
