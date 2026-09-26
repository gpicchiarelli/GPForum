# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::I18N::Formatter;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;
use DateTime;
use DateTime::TimeZone;
use POSIX       qw(strftime);
use Time::Local qw(timegm);

our $VERSION = '0.001';

const my $SINGULAR_COUNT     => 1;
const my $SECONDS_PER_HOUR   => 3600;
const my $SECONDS_PER_MINUTE => 60;

# Capture positions in the assembled timestamp pattern: year, month, day,
# hour, minute, second, then the Z marker and the numeric offset.
const my $LAST_TIME_CAPTURE  => 5;
const my $FIRST_ZONE_CAPTURE => 7;
const my $LAST_ZONE_CAPTURE  => 9;

# Split so no single pattern is an unreadable wall. Together they accept both
# shapes this application produces: Clock's "2026-05-23T12:00:00Z" and
# DBD::Pg's "2026-05-23 12:00:00+00".
const my $DATE_PART =>
  qr/([[:digit:]]{4}) - ([[:digit:]]{2}) - ([[:digit:]]{2})/msx;
const my $CLOCK_PART => qr/([[:digit:]]{2}) : ([[:digit:]]{2})/msx;
const my $SECONDS_PART =>
  qr/(?: : ([[:digit:]]{2}) )? (?: [.] [[:digit:]]+ )? \s*/msx;
const my $ZONE_PART =>
  qr/(?: (Z) | ([+-]) ([[:digit:]]{2}) :? ([[:digit:]]{2})? )?/msx;

has locale_table => undef;

# Each takes an optional IANA time zone (9.3). Without one they answer in
# UTC, as they always did; with one they convert, and a time also names the
# zone it is shown in, so a reader never has to guess.
sub format_date ( $self, $locale, $epoch, $zone = undef ) {
    return $self->_strftime(
        {
            field  => 'date_format',
            locale => $locale,
            value  => $epoch,
            zone   => $zone
        }
    );
}

sub format_time ( $self, $locale, $epoch, $zone = undef ) {
    return $self->_strftime(
        {
            field  => 'time_format',
            locale => $locale,
            value  => $epoch,
            zone   => $zone
        }
    );
}

sub format_datetime ( $self, $locale, $epoch, $zone = undef ) {
    return $self->_strftime(
        {
            field  => 'datetime_format',
            locale => $locale,
            value  => $epoch,
            zone   => $zone
        }
    );
}

sub format_number ( $self, $locale, $number ) {
    my $metadata = $self->locale_table->metadata($locale);
    my $safe     = $self->_numeric($number);
    my $parts    = $self->_number_parts($safe);

    return $self->_join_number( $parts, $metadata );
}

sub plural_category ( $, $, $count ) {
    if ( $count == $SINGULAR_COUNT ) {
        return 'one';
    }

    return 'other';
}

# gmtime, not localtime. These render timestamptz values that the database
# stores in UTC; formatting them in whatever zone the server happens to sit in
# made the same row read differently on two machines and gave no way to tell
# which zone was shown. Per-user timezones are 9.3; until then UTC is the one
# answer that is the same everywhere and matches what is stored.
sub _strftime ( $self, $request ) {
    my $epoch = _epoch( $request->{value} );

    # A missing or unparseable timestamp renders as nothing, so the caller can
    # show its own placeholder. Returning 1970-01-01 -- which is what falling
    # back to 0 produced -- is a date the reader has no reason to distrust.
    return if !defined $epoch;

    my $format =
      $self->locale_table->metadata( $request->{locale} )
      ->{ $request->{field} };
    my $zone = $request->{zone};
    return strftime( $format, gmtime $epoch ) if !defined $zone;

    my $named = $request->{field} eq 'date_format' ? $format : "$format %Z";

    return DateTime->from_epoch(
        epoch     => $epoch,
        time_zone => _time_zone($zone),
    )->strftime($named);
}

# Building a zone reads its rules; one object per zone name serves every
# request. An unknown name is UTC: a stale or mistyped preference must not
# take the page down.
my %ZONE_CACHE;

sub _time_zone ($name) {
    return $ZONE_CACHE{$name} //=
        DateTime::TimeZone->is_valid_name($name)
      ? DateTime::TimeZone->new( name => $name )
      : DateTime::TimeZone->new( name => 'UTC' );
}

sub valid_time_zone ( $, $name ) {
    return
      defined $name && length $name && DateTime::TimeZone->is_valid_name($name)
      ? 1
      : 0;
}

sub time_zone_names ($self) {
    return [ DateTime::TimeZone->all_names ];
}

# The application's timestamps are ISO-8601 strings -- Clock::now_iso8601
# emits "2026-05-23T12:00:00Z" and DBD::Pg renders timestamptz as
# "2026-05-23 12:00:00+00" -- and this took an epoch. Passing a real
# application timestamp numified it to its leading year: every date on the
# site would have rendered as 1970-01-01, with a warning. Both shapes are
# accepted now, and an unparseable value returns undef rather than a date that
# is confidently wrong.
sub _epoch ($value) {
    return        if !defined $value;
    return $value if $value =~ /\A -? [[:digit:]]+ \z/msx;

    my $parsed = _epoch_from_iso8601($value);
    return $parsed if defined $parsed;

    return;
}

sub _epoch_from_iso8601 ($value) {

    # Assembled from the named parts above rather than written out here, so
    # each piece of the grammar can be read on its own.
    my @parts = $value =~ m{
        \A \s* $DATE_PART [T\s] $CLOCK_PART $SECONDS_PART $ZONE_PART \s* \z
    }msx;
    return if !@parts;

    my ( $year, $month, $day, $hour, $minute, $seconds ) =
      @parts[ 0 .. $LAST_TIME_CAPTURE ];
    my $epoch = eval {
        return timegm( $seconds || 0, $minute, $hour, $day, $month - 1, $year );
    };
    return if !defined $epoch;

    return $epoch -
      _offset_seconds( @parts[ $FIRST_ZONE_CAPTURE .. $LAST_ZONE_CAPTURE ] );
}

sub _offset_seconds ( $sign, $hours, $minutes ) {
    return 0 if !defined $sign;

    my $seconds =
      ( $hours * $SECONDS_PER_HOUR ) +
      ( ( $minutes || 0 ) * $SECONDS_PER_MINUTE );

    return $sign eq q{-} ? -$seconds : $seconds;
}

sub _numeric ( $self, $number ) {
    if ( $self->_is_number($number) ) {
        return $number;
    }

    return 0;
}

sub _is_number ( $, $number ) {
    if ( !defined $number ) {
        return 0;
    }
    if ( $number =~ /\A -? [[:digit:]]+ (?:[.][[:digit:]]+)? \z/msx ) {
        return 1;
    }

    return 0;
}

sub _number_parts ( $, $number ) {
    my $formatted = sprintf '%.2f', $number;
    my ( $whole, $fraction ) = split /[.]/msx, $formatted;
    my $sign = q{};
    if ( $whole =~ s/\A-//msx ) {
        $sign = q{-};
    }

    return {
        fraction => $fraction,
        sign     => $sign,
        whole    => $whole,
    };
}

sub _join_number ( $self, $parts, $metadata ) {
    my $whole =
      $self->_group_thousands( $parts->{whole}, $metadata->{thousand_mark} );

    return
        $parts->{sign}
      . $whole
      . $metadata->{decimal_mark}
      . $parts->{fraction};
}

# Grouped from the right, repeatedly, over the still-ungrouped leading digits.
# The previous version anchored the match to the end of the whole string, so
# once it had inserted one separator the separator itself blocked every later
# match and the loop stopped: 1234567 formatted as "1234,567" rather than
# "1,234,567". Nothing noticed because no template called the formatter.
sub _group_thousands ( $, $whole, $mark ) {
    my $grouped = $whole;
    while ( $grouped =~ s/\A ([[:digit:]]+) ([[:digit:]]{3})/$1$mark$2/msx ) {
        next;
    }

    return $grouped;
}

1;

__END__

=head1 NAME

GPForum::Service::I18N::Formatter - Locale-aware date and number formatting.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $date = $formatter->format_date( 'it', $epoch );

=head1 DESCRIPTION

Owns date, time, datetime, and number formatting plus the one/other plural
category. Locale metadata comes from L<GPForum::Service::I18N::Locale>.
L<GPForum::Service::I18N> remains the public facade.

=head1 SUBROUTINES/METHODS

=head2 format_date

Formats an epoch with the locale date pattern.

=head2 format_time

Formats an epoch with the locale time pattern.

=head2 format_datetime

Formats an epoch with the locale datetime pattern.

=head2 format_number

Formats a decimal with locale thousand and decimal marks.

=head2 plural_category

Returns C<one> for count 1 and C<other> otherwise.

=head1 DIAGNOSTICS

Undefined epochs and non-numeric values format as zero.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a C<locale_table> that can return locale metadata.

=head1 DEPENDENCIES

Uses L<POSIX> C<strftime>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Number grouping uses a simple three-digit loop, not CLDR compact forms.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
