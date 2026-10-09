# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';

use GPForum::Service::Forum::BodyRenderer;

our $VERSION = '0.001';

# The rules of BodyRenderer that t/179 and t/186 leave unpinned, each with
# the exact markup it gives: which links become anchors, where emphasis
# stops, which lines open and close a fence or a quote, and how line endings
# and empty blocks are joined. Every expectation is what the renderer gave
# before its helpers were folded together.

my $renderer = GPForum::Service::Forum::BodyRenderer->new;
my $rel      = 'rel="nofollow noopener noreferrer"';

my @cases = (
    [
        '[x](https://e.x/"q)',
        '<p>[x](https://e.x/&quot;q)</p>',
        'a URL holding an entity other than &amp; is not linked'
    ],
    [
        '[x](https://e.x/?a=1&b=2)',
        qq{<p><a href="https://e.x/?a=1&amp;b=2" $rel>x</a></p>},
        'a URL whose only entity is &amp; is linked'
    ],
    [
        '[x](https://e.x/a b)',
        '<p>[x](https://e.x/a b)</p>',
        'a URL with a space is not linked'
    ],
    [
        '[x](HTTPS://e.x/)',
        qq{<p><a href="HTTPS://e.x/" $rel>x</a></p>},
        'the scheme is matched without regard to case, the URL kept as typed'
    ],
    [
        '[x](MailTo:a@e.x)',
        qq{<p><a href="MailTo:a\@e.x" $rel>x</a></p>},
        'a mailto link of any case is linked'
    ],
    [
        '[x](javascript:alert(1))',
        '<p>[x](javascript:alert(1))</p>',
        'a scheme outside http, https and mailto is not linked'
    ],
    [
        '![x](https://e.x/i.png)',
        '<p>![x](https://e.x/i.png)</p>',
        'an image is not turned into a link'
    ],
    [ "*a\nb*", '<p>*a<br>b*</p>', 'emphasis does not cross a line' ],
    [ 'a ** b', '<p>a ** b</p>',   'a pair around nothing stays as typed' ],
    [ "a\rb",   '<p>a<br>b</p>',   'a lone carriage return ends a line' ],
    [
        "```a`b\nx\n```",
        "<p>``<code>a</code>b<br>x</p>\n<p>```</p>",
        'an info string with a backtick opens no fence'
    ],
    [
        "```\nx\n```y\nz\n```",
        "<pre><code>x\n```y\nz</code></pre>",
        'a backtick line with text after it does not close a fence'
    ],
    [
        '    > q',
        '<p>    &gt; q</p>',
        'a quote marker indented four spaces is text'
    ],
    [
        '   > q',
        '<blockquote><p>q</p></blockquote>',
        'a quote marker indented three spaces opens a quote'
    ],
    [
        "```\na\n```\n\n```\nb\n```",
        "<pre><code>a</code></pre>\n<pre><code>b</code></pre>",
        'blank prose between fences adds no empty line'
    ],
    [
        '[x](https://e.x/) wow!',
        qq{<p><a href="https://e.x/" $rel>x</a> wow!</p>},
        'a link at the start is linked when the text ends in "!"'
    ],
    [
        "    ```\nx\n```",
        "<p>    ```<br>x</p>\n<p>```</p>",
        'a fence marker indented four spaces is text'
    ],
    [ "a\n\nb", "<p>a</p>\n<p>b</p>", 'a blank line ends a paragraph' ],
    [
        "> a\n\n> b",
        "<blockquote><p>a</p></blockquote>\n<blockquote><p>b</p></blockquote>",
        'a blank line ends a quote'
    ],
    [
        "> a\n>\n> b",
        "<blockquote><p>a</p>\n<p>b</p></blockquote>",
        'an empty quoted line splits the quote into paragraphs'
    ],
    [
        "`a\nb` `c`",
        q{<p>`a<br>b<code> </code>c`</p>},
        'a code span does not cross a line'
    ],
    [
        '[*x](https://e.x/) y*',
        qq{<p><a href="https://e.x/" $rel>*x</a> y*</p>},
        'emphasis does not reach across the end of a link'
    ],
    [
        '[x](https://e.x/) and (y)',
        qq{<p><a href="https://e.x/" $rel>x</a> and (y)</p>},
        'a link ends at the first ")" after its URL opens'
    ],
    [
        '[a](https://e.x/a) [b](https://e.x/b)',
        qq{<p><a href="https://e.x/a" $rel>a</a> }
          . qq{<a href="https://e.x/b" $rel>b</a></p>},
        'two links on a line are both linked'
    ],
    [
        "> a\nb",
        "<blockquote><p>a</p></blockquote>\n<p>b</p>",
        'an unquoted line after a quote starts a paragraph'
    ],
    [
        "a\n> b",
        "<p>a</p>\n<blockquote><p>b</p></blockquote>",
        'a quoted line after a paragraph starts a quote'
    ],
    [
        ">\n> a\n>",
        '<blockquote><p>a</p></blockquote>',
        'empty quoted lines around a quote add no empty paragraph'
    ],
);

plan tests => scalar @cases;

for my $case (@cases) {
    my ( $source, $expected, $name ) = @{$case};
    is( $renderer->render_safe($source), $expected, $name );
}

1;
