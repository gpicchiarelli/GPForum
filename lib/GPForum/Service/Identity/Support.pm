package GPForum::Service::Identity::Support;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use Mojo::Base -base;
use POSIX       qw(strftime);
use Time::Local qw(timegm_modern);

our $VERSION = '0.001';

const my $SECONDS_PER_MINUTE => 60;
const my $SECONDS_PER_HOUR   => 3_600;
const my $DATE_PART =>
  qr{([[:digit:]]{4})-([[:digit:]]{2})-([[:digit:]]{2})}msx;
const my $TIME_PART =>
  qr{([[:digit:]]{2}):([[:digit:]]{2}):([[:digit:]]{2})}msx;
const my $ZONE_PART => qr{(Z|[+-][[:digit:]]{2}(?::?[[:digit:]]{2})?)?}msx;
const my $TIMESTAMP =>
  qr{\A $DATE_PART [T ] $TIME_PART (?:[.][[:digit:]]+)? \s* $ZONE_PART \z}msx;
const my $ZONE_OFFSET =>
  qr{\A ([+-]) ([[:digit:]]{2}) :? ([[:digit:]]{2})? \z}msx;

sub column {
    my ( undef, $row, $name ) = @_;

    if ( ref $row eq 'HASH' ) {
        return $row->{$name};
    }
    if ( $row && $row->can('get_column') ) {
        return $row->get_column($name);
    }

    return;
}

sub update_row {
    my ( $self, $row, $values ) = @_;

    if ( ref $row eq 'HASH' ) {
        return $self->_merge_hash( $row, $values );
    }

    return $row->update($values);
}

sub has_text {
    my ( undef, $value ) = @_;

    return defined $value && length $value ? 1 : 0;
}

sub trim {
    my ( undef, $value ) = @_;

    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub normalize_identifier {
    my ( $self, $value ) = @_;

    return lc $self->trim($value);
}

sub hash_value {
    my ( $self, $value ) = @_;

    my $digest;
    if ( $self->has_text($value) ) {
        $digest = sha256_hex($value);
    }

    return $digest;
}

sub iso8601_from_epoch {
    my ( undef, $epoch ) = @_;

    return strftime '%Y-%m-%dT%H:%M:%SZ', gmtime $epoch;
}

sub epoch_from_timestamp {
    my ( undef, $value ) = @_;

    if ( !defined $value ) {
        return;
    }
    my @parts = $value =~ $TIMESTAMP;
    if ( !@parts ) {
        return;
    }

    my $zone = pop @parts;
    my ( $year, $month, $day, $hour, $minute, $seconds ) = @parts;
    my $epoch = eval {
        return timegm_modern( $seconds, $minute, $hour, $day, $month - 1,
            $year );
    };
    if ( !defined $epoch ) {
        return;
    }

    return $epoch - _zone_offset_seconds($zone);
}

sub _zone_offset_seconds {
    my ($zone) = @_;

    my ( $sign, $hours, $minutes ) = ( $zone || q{} ) =~ $ZONE_OFFSET;
    if ( !defined $sign ) {
        return 0;
    }

    my $offset =
      $hours * $SECONDS_PER_HOUR + ( $minutes || 0 ) * $SECONDS_PER_MINUTE;

    return $sign eq q{-} ? -$offset : $offset;
}

sub _merge_hash {
    my ( undef, $row, $values ) = @_;

    for my $key ( keys %{$values} ) {
        $row->{$key} = $values->{$key};
    }

    return $row;
}

1;

__END__

=head1 NAME

GPForum::Service::Identity::Support - Shared identity persistence helpers.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $value = GPForum::Service::Identity::Support->new->column($row, 'id');

=head1 DESCRIPTION

Owns row/hash access, identifier normalization, and hashing used by identity
stores.

=head1 SUBROUTINES/METHODS

=head2 column

Reads a named field from a hash or DBIx::Class row.

=head2 update_row

Writes a value hash onto a hash or DBIx::Class row.

=head2 has_text

True when the value is defined and non-empty.

=head2 trim

Strips surrounding whitespace.

=head2 normalize_identifier

Lowercases and trims an identifier.

=head2 hash_value

Returns a SHA-256 hex digest, or undef for empty input.

=head2 iso8601_from_epoch

Formats a UTC ISO-8601 timestamp.

=head2 epoch_from_timestamp

Parses an ISO-8601 (C<2026-05-23T12:00:00Z>) or PostgreSQL
C<timestamp with time zone> text value (C<2026-05-23 14:00:00.123+02>) into
epoch seconds. Returns undef for missing or unparseable values.

=head1 DIAGNOSTICS

None. These helpers do not raise application errors.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Digest::SHA>, L<POSIX>, and L<Time::Local>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Hash rows are mutated in place by C<update_row>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
