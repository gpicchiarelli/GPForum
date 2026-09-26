# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;
use utf8;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Forum::BodyRenderer;
use GPForum::Service::Identity::Registration;

our $VERSION = '0.001';

# --- usernames are identifiers, so they are ASCII ------------------------
#
# The format check was /\A [[:lower:]] [[:lower:][:digit:]_]+ \z/. Under
# Unicode semantics that POSIX class matches a lowercase letter in any script,
# so these registered as distinct accounts that a reader cannot tell apart from
# the ones they impersonate. The username appears in profile URLs, mentions and
# moderation records.
## no critic (ValuesAndExpressions::ProhibitEscapedCharacters)
# Escapes on purpose. Pasting the literal homoglyphs would put characters into
# this file that are invisibly different from ASCII, which is exactly the
# property under test and exactly what a reader could not verify.
const my %HOMOGLYPH => (
    'Cyrillic a'       => "\x{0430}dmin",
    'Cyrillic i'       => "adm\x{0456}n",
    'Greek omicron'    => "\x{03BF}wner",
    'Armenian ayb'     => "\x{0561}dmin",
    'fullwidth letter' => "\x{FF41}dmin",
);
## use critic

for my $label ( sort keys %HOMOGLYPH ) {
    my $result =
      GPForum::Service::Identity::Registration->new->prepare(
        _registration( $HOMOGLYPH{$label} ) );
    ok( $result->{errors}{username}, "a username using $label is refused" );
}

for my $good (qw(admin good_name7 a_b)) {
    my $result =
      GPForum::Service::Identity::Registration->new->prepare(
        _registration($good) );
    ok( !$result->{errors}{username}, "an ASCII username '$good' is accepted" );
}

# --- emphasis must not rewrite a URL -------------------------------------
#
# _inline runs _emphasis after _links, over the anchors that pass emitted, so
# a star inside an href was treated as markup:
# [docs](https://example.com/a*b*c) came out with <em> tags inside the
# attribute.
my $renderer = GPForum::Service::Forum::BodyRenderer->new;

my $starred = $renderer->render_safe('[docs](https://example.com/a*b*c)');
like(
    $starred,
    qr{href="https://example[.]com/a[*]b[*]c"}msx,
    'a star in an href survives the emphasis pass'
);
unlike( $starred, qr{href="[^"]*<em>}msx, 'no tag is written into an href' );

my $strong = $renderer->render_safe('[w](https://example.com/Foo**Bar**Baz)');
unlike( $strong, qr{href="[^"]*<strong>}msx,
    'a double star in an href survives too' );

# The link text is its own segment, so emphasis there still works.
like(
    $renderer->render_safe('[*styled*](https://example.com/p)'),
    qr{<a [^>]*><em>styled</em></a>}msx,
    'emphasis inside link text still renders'
);

# And ordinary prose is untouched by the change.
like(
    $renderer->render_safe('plain *emphasis* and **strong**'),
    qr{<em>emphasis</em> \s and \s <strong>strong</strong>}msx,
    'prose emphasis and strong still render'
);

done_testing();

sub _registration {
    my ($username) = @_;

    return {
        display_name     => 'Someone',
        email            => 'someone@example.test',
        password         => 'correct horse battery staple',
        password_confirm => 'correct horse battery staple',
        username         => $username,
    };
}

1;
