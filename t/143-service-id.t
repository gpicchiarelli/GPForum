# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::Id;
use GPForum::Test::Id;
use Test::More;

our $VERSION = '0.001';

ok( !exists $INC{'Crypt/URandom.pm'},
    'Crypt::URandom stays unloaded when Id compiles' );

ok(
    GPForum::Infrastructure::Id->new,
    'Id constructs without generating a UUID'
);
is( GPForum::Test::Id->new->uuid,
    'generated-1', 'injected Test::Id still supplies identifiers' );

ok( !exists $INC{'Crypt/URandom.pm'},
    'Crypt::URandom stays unloaded after construct and Test::Id' );

# is_uuid guards uuid columns: what passes it, PostgreSQL must accept.
ok(
    GPForum::Infrastructure::Id->is_uuid(
        GPForum::Infrastructure::Id->new->uuid
    ),
    'a generated uuid is a uuid'
);
ok(
    GPForum::Infrastructure::Id->is_uuid(
        '018F1000-0000-7000-8000-0000000000FF'),
    'in either case'
);
ok( !GPForum::Infrastructure::Id->is_uuid(undef),           'undef is not' );
ok( !GPForum::Infrastructure::Id->is_uuid('dead-letter-1'), 'a word is not' );
ok(
    !GPForum::Infrastructure::Id->is_uuid(
        "018f1000-0000-7000-8000-0000000000ff\n"),
    'nor a uuid with a trailing newline'
);

# [[:xdigit:]] matches the fullwidth digits and letters too, and Mojolicious
# decodes a percent-encoded path, so this reached the uuid column and came
# back as a database error instead of a 404.
ok(
    !GPForum::Infrastructure::Id->is_uuid(
        "\N{FULLWIDTH DIGIT ZERO}18f1000-0000-7000-8000-0000000000ff"),
    'fullwidth hex digits are not ASCII hex'
);

done_testing();

1;
