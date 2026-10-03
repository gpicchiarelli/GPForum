# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Community::MentionExtractor;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 5;
const my $MENTION_COUNT  => 2;
const my $AT_CODE        => 64;
const my $AT_SIGN        => chr $AT_CODE;

plan tests => $EXPECTED_TESTS;

# Mention extraction is plain text work. The bookmark, mention, feed and
# reputation stores that ran here on a fake ORM run on PostgreSQL now:
# t/integration/postgres-community.t.
my $extractor = GPForum::Service::Community::MentionExtractor->new;
my $mentions  = $extractor->extract(
    join q{},
    'Ciao ',
    $AT_SIGN,
    'Giacomo, grazie a ',
    $AT_SIGN,
    'alice e ancora ',
    $AT_SIGN,
    'giacomo. Email a',
    $AT_SIGN,
    'b.it no.'
);

is( scalar @{$mentions},      $MENTION_COUNT, 'mentions are unique' );
is( $mentions->[0]{username}, 'giacomo', 'mention usernames are normalized' );
is( $mentions->[0]{label}, $AT_SIGN . 'giacomo', 'mention label is explicit' );
is( $mentions->[1]{username}, 'alice',           'second mention is detected' );
is_deeply( $extractor->extract(undef), [], 'empty body has no mentions' );

1;
