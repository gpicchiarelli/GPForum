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
use GPForum::Test::FixedClock;

our $VERSION = '0.001';

const my $STORED      => '2026-05-23T12:00:00Z';
const my $EPOCH_VALUE => 1_779_969_600;
const my $MILLION     => 1_234_567.5;
const my $BILLIONISH  => 1_234_567_890;
const my $NEGATIVE    => -9_876_543.21;

# Relative times: $STORED as an epoch, and the units the phrases count in.
const my $NOON         => 1_779_537_600;
const my $MINUTE       => 60;
const my $HOUR         => 3_600;
const my $DAY          => 86_400;
const my $WEEK         => 604_800;
const my $LAST_MINUTES => 59;
const my $LAST_HOURS   => 23;
const my $LAST_DAYS    => 6;
const my $SEVERAL      => 5;
const my $A_FEW        => 3;

my $i18n    = GPForum::Service::I18N->new;
my $formats = $i18n->formats;
my $clock   = GPForum::Test::FixedClock->new( epoch => $NOON );
$formats->clock($clock);

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

# The datetime attribute needs one valid shape. PostgreSQL's "+00" offset has
# no minutes, so it is not an HTML global date and time string; every shape
# the application produces comes out as UTC with a Z.
is( $formats->iso8601($STORED), $STORED, 'a Clock timestamp is already ISO' );
is( $formats->iso8601('2026-05-23 14:00:00+02'),
    $STORED, 'a PostgreSQL timestamp is converted to UTC' );
is( $formats->iso8601($NOON),        $STORED, 'an epoch is written out' );
is( $formats->iso8601('not a date'), undef,   'an unparseable value is undef' );

# Relative times. The phrase is elapsed time; the absolute time and the date
# are in the reader's zone; datetime is the instant.
$clock->epoch( $NOON + $A_FEW * $MINUTE );
is_deeply(
    $formats->relative_datetime( 'it', $STORED, 'Europe/Rome' ),
    {
        absolute => '23/05/2026 14:00 CEST',
        count    => $A_FEW,
        date     => '23/05/2026',
        datetime => $STORED,
        phrase   => 'common.time_minutes_ago',
    },
    'three minutes on, a member in Rome gets the phrase and Rome time'
);
is_deeply(
    $formats->relative_datetime( 'en', '2026-05-23 12:00:00+00' ),
    {
        absolute => '2026-05-23 12:00',
        count    => $A_FEW,
        date     => '2026-05-23',
        datetime => $STORED,
        phrase   => 'common.time_minutes_ago',
    },
    'the PostgreSQL shape reads the same, in UTC when no zone is given'
);
is( $formats->relative_datetime( 'en', 'not a date' ),
    undef, 'an unparseable value has no relative time' );
is( $formats->relative_datetime( 'en', undef ),
    undef, 'nor has a missing one' );

# Each boundary, from both sides: the age in seconds, then the phrase and
# count expected -- none past the window, where the page shows the date.
my @boundaries = (
    [ 0,               'common.time_now',         0, 'the moment itself' ],
    [ $MINUTE - 1,     'common.time_now',         0, 'just under a minute' ],
    [ $MINUTE,         'common.time_minutes_ago', 1, 'a full minute' ],
    [ 2 * $MINUTE - 1, 'common.time_minutes_ago', 1, 'counts round down' ],
    [ 2 * $MINUTE,     'common.time_minutes_ago', 2, 'two minutes' ],
    [ $HOUR - 1, 'common.time_minutes_ago', $LAST_MINUTES, 'the last minute' ],
    [ $HOUR,     'common.time_hours_ago',   1,             'a full hour' ],
    [ $DAY - 1,  'common.time_hours_ago',   $LAST_HOURS,   'the last hour' ],
    [ $DAY,      'common.time_days_ago',    1,             'a full day' ],
    [ $WEEK - 1, 'common.time_days_ago',    $LAST_DAYS,    'the last day' ],
    [ $WEEK,     undef,             undef, 'a week old: the date instead' ],
    [ -$MINUTE,  'common.time_now', 0,     'a minute ahead (clock skew)' ],
    [ -$MINUTE - 1, undef,          undef, 'further ahead: the date instead' ],
);
for my $case (@boundaries) {
    my ( $age, $phrase, $count, $label ) = @{$case};
    $clock->epoch( $NOON + $age );
    my $when = $formats->relative_datetime( 'en', $STORED );
    is_deeply(
        [ $when->{phrase}, $when->{count} ],
        [ $phrase,         $count ],
        "at $age seconds: $label"
    );
}
$clock->epoch( $NOON + $WEEK );
is( $formats->relative_datetime( 'it', $STORED, 'Europe/Rome' )->{date},
    '23/05/2026', 'past the window there is the date to show' );

# The phrases in every locale, with the plural forms each language needs:
# English and Italian both say the singular in words.
my %phrases = (
    en => {
        'common.time_days_ago'    => [ 'a day ago',    '5 days ago' ],
        'common.time_hours_ago'   => [ 'an hour ago',  '5 hours ago' ],
        'common.time_minutes_ago' => [ 'a minute ago', '5 minutes ago' ],
        'common.time_now'         => [ 'just now',     'just now' ],
    },
    it => {
        'common.time_days_ago'  => [ 'un giorno fa', '5 giorni fa' ],
        'common.time_hours_ago' =>
          [ "un\N{RIGHT SINGLE QUOTATION MARK}ora fa", '5 ore fa' ],
        'common.time_minutes_ago' => [ 'un minuto fa', '5 minuti fa' ],
        'common.time_now'         => [ 'adesso',       'adesso' ],
    },
);
is_deeply( [ sort keys %phrases ],
    $i18n->supported_locales,
    'every supported locale has its phrases checked' );
for my $locale ( sort keys %phrases ) {
    for my $key ( sort keys %{ $phrases{$locale} } ) {
        my ( $one, $other ) = @{ $phrases{$locale}{$key} };
        is( $i18n->translate_count( $locale, $key, 1 ),
            $one, "$locale $key, one" );
        is( $i18n->translate_count( $locale, $key, $SEVERAL ),
            $other, "$locale $key, other" );
    }
}

done_testing();

1;
