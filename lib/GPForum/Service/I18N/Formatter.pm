package GPForum::Service::I18N::Formatter;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;
use POSIX qw(strftime);

our $VERSION = '0.001';

const my $SINGULAR_COUNT => 1;

has locale_table => undef;

sub format_date {
    my ( $self, $locale, $epoch ) = @_;

    return $self->_strftime( $locale, 'date_format', $epoch );
}

sub format_time {
    my ( $self, $locale, $epoch ) = @_;

    return $self->_strftime( $locale, 'time_format', $epoch );
}

sub format_datetime {
    my ( $self, $locale, $epoch ) = @_;

    return $self->_strftime( $locale, 'datetime_format', $epoch );
}

sub format_number {
    my ( $self, $locale, $number ) = @_;

    my $metadata = $self->locale_table->metadata($locale);
    my $safe     = $self->_numeric($number);
    my $parts    = $self->_number_parts($safe);

    return $self->_join_number( $parts, $metadata );
}

sub plural_category {
    my ( undef, undef, $count ) = @_;

    if ( $count == $SINGULAR_COUNT ) {
        return 'one';
    }

    return 'other';
}

sub _strftime {
    my ( $self, $locale, $field, $epoch ) = @_;

    my $metadata = $self->locale_table->metadata($locale);

    return strftime( $metadata->{$field}, localtime $self->_epoch($epoch) );
}

sub _epoch {
    my ( undef, $epoch ) = @_;

    if ( defined $epoch ) {
        return $epoch;
    }

    return 0;
}

sub _numeric {
    my ( $self, $number ) = @_;

    if ( $self->_is_number($number) ) {
        return $number;
    }

    return 0;
}

sub _is_number {
    my ( undef, $number ) = @_;

    if ( !defined $number ) {
        return 0;
    }
    if ( $number =~ /\A -? [[:digit:]]+ (?:[.][[:digit:]]+)? \z/msx ) {
        return 1;
    }

    return 0;
}

sub _number_parts {
    my ( undef, $number ) = @_;

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

sub _join_number {
    my ( $self, $parts, $metadata ) = @_;

    my $whole =
      $self->_group_thousands( $parts->{whole}, $metadata->{thousand_mark} );

    return
        $parts->{sign}
      . $whole
      . $metadata->{decimal_mark}
      . $parts->{fraction};
}

sub _group_thousands {
    my ( undef, $whole, $mark ) = @_;

    my $grouped = $whole;
    while (1) {
        my $next = _next_group( $grouped, $mark );
        if ( $next eq $grouped ) {
            last;
        }
        $grouped = $next;
    }

    return $grouped;
}

sub _next_group {
    my ( $whole, $mark ) = @_;

    if ( $whole =~ /\A ([[:digit:]]+) ([[:digit:]]{3}) \z/msx ) {
        return $1 . $mark . $2;
    }

    return $whole;
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
