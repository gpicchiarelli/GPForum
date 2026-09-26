# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::I18N;

our $VERSION = '0.001';

const my $STORED      => '2026-05-23T12:00:00Z';
const my $EPOCH_VALUE => 1_779_969_600;
const my $MILLION     => 1_234_567.5;
const my $BILLIONISH  => 1_234_567_890;
const my $NEGATIVE    => -9_876_543.21;

my $formats = GPForum::Service::I18N->new->formats;

# The formatter took an epoch while every timestamp in this application is an
# ISO-8601 string: Clock::now_iso8601 emits "...T12:00:00Z" and DBD::Pg renders
# timestamptz as "... 12:00:00+00". Passing a real one numified it to its
# leading year, so every date would have rendered as 1970-01-01.
is(
    $formats->format_datetime( 'en', $STORED ),
    '2026-05-23 12:00',
    'an ISO-8601 timestamp formats as itself'
);
is(
    $formats->format_datetime( 'en', '2026-05-23 12:00:00+00' ),
    '2026-05-23 12:00',
    'the PostgreSQL rendering formats too'
);
is(
    $formats->format_datetime( 'en', '2026-05-23 14:00:00+02' ),
    '2026-05-23 12:00',
    'a non-UTC offset is converted, not ignored'
);
is(
    $formats->format_datetime( 'en', $EPOCH_VALUE ),
    '2026-05-28 12:00',
    'a numeric epoch still works'
);

# UTC, not the server's zone: the same row must read the same on two machines.
is( $formats->format_date( 'en', '2026-05-23T23:30:00Z' ),
    '2026-05-23', 'a late-evening UTC timestamp keeps its UTC date' );

# A value it cannot read yields nothing, so a caller can show its own
# placeholder instead of a date the reader has no reason to distrust.
is( $formats->format_datetime( 'en', 'not a date' ),
    undef, 'an unparseable value formats as undef' );
is( $formats->format_datetime( 'en', undef ),
    undef, 'a missing value formats as undef' );

# Locale actually changes the rendering.
is(
    $formats->format_datetime( 'it', $STORED ),
    '23/05/2026 12:00',
    'the Italian locale uses its own date order'
);

# 9.3: a reader's own time zone, named on the page. Without one the formatter
# keeps its UTC answer; with one it converts, and says which zone it shows.
is(
    $formats->format_datetime( 'it', $STORED, 'Europe/Rome' ),
    '23/05/2026 14:00 CEST',
    'a member in Rome reads Rome time, and is told so'
);
is(
    $formats->format_datetime( 'en', $STORED, 'America/New_York' ),
    '2026-05-23 08:00 EDT',
    'a member in New York reads New York time'
);
is(
    $formats->format_datetime( 'en', $STORED, 'UTC' ),
    '2026-05-23 12:00 UTC',
    'UTC is named too, once a zone is in play'
);
is( $formats->format_date( 'en', '2026-05-23T23:30:00Z', 'Europe/Rome' ),
    '2026-05-24', 'the date follows the zone across midnight' );
is(
    $formats->format_datetime( 'en', $STORED, 'Mars/Olympus_Mons' ),
    '2026-05-23 12:00 UTC',
    'an unknown zone falls back to UTC, not an error'
);

# Grouping was anchored to the end of the string, so it inserted one separator
# and then the separator blocked every later match: 1234567 came out "1234,567".
is( $formats->format_number( 'en', $MILLION ),
    '1,234,567.50', 'English groups every three digits' );
is( $formats->format_number( 'it', $MILLION ),
    '1.234.567,50', 'Italian groups with its own marks' );
is( $formats->format_number( 'en', $BILLIONISH ),
    '1,234,567,890.00', 'grouping continues past a million' );
is( $formats->format_number( 'en', $NEGATIVE ),
    '-9,876,543.21', 'a negative number keeps its sign outside the grouping' );

done_testing();

1;
