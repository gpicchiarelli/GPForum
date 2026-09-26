# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Infrastructure::Id;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use Const::Fast;

our $VERSION = '0.001';

const my $UUID_RANDOM_BYTES  => 10;
const my $MILLISECONDS       => 1_000;
const my $BYTE_MASK          => 0xff;
const my $VERSION_MASK       => 0x0f;
const my $VERSION_SEVEN      => 0x70;
const my $VARIANT_MASK       => 0x3f;
const my $VARIANT_RFC4122    => 0x80;
const my $VERSION_BYTE_INDEX => 6;
const my $VARIANT_BYTE_INDEX => 8;
const my @TIMESTAMP_SHIFTS   => ( 40, 32, 24, 16, 8, 0 );
const my @UUID_CHUNK_LENGTHS => ( 8,  4,  4,  4,  12 );

# /a: without it [[:xdigit:]] also matches the fullwidth digits and letters
# (U+FF10...), which PostgreSQL's uuid input rejects.
const my $UUID_PATTERN =>
  qr/\A [[:xdigit:]]{8} (?: - [[:xdigit:]]{4} ){3} - [[:xdigit:]]{12} \z/msxa;

# The shape of a uuid. A value from a URL or a form that does not have it must
# be refused before it reaches a uuid column: PostgreSQL rejects the whole
# statement, which surfaces as a 500 instead of a 404 or a 400.
sub uuid_pattern ($class) {
    return $UUID_PATTERN;
}

sub is_uuid ( $class, $value ) {
    return defined $value && $value =~ $UUID_PATTERN ? 1 : 0;
}

sub uuid ($self) {
    my $timestamp_ms = int( time * $MILLISECONDS );
    my @bytes = map { ( $timestamp_ms >> $_ ) & $BYTE_MASK } @TIMESTAMP_SHIFTS;

    push @bytes, unpack 'C*', _random_bytes($UUID_RANDOM_BYTES);

    $bytes[$VERSION_BYTE_INDEX] =
      ( $bytes[$VERSION_BYTE_INDEX] & $VERSION_MASK ) | $VERSION_SEVEN;
    $bytes[$VARIANT_BYTE_INDEX] =
      ( $bytes[$VARIANT_BYTE_INDEX] & $VARIANT_MASK ) | $VARIANT_RFC4122;

    return $self->_format_uuid_bytes( \@bytes );
}

sub _format_uuid_bytes ( $self, $bytes ) {
    my $hex    = unpack 'H*', pack 'C*', @{$bytes};
    my @chunks = ();
    my $offset = 0;

    for my $length (@UUID_CHUNK_LENGTHS) {
        push @chunks, substr $hex, $offset, $length;
        $offset += $length;
    }

    return join q{-}, @chunks;
}

sub _random_bytes ($bytes) {
    require Crypt::URandom;
    return Crypt::URandom::urandom($bytes);
}

1;

__END__

=head1 NAME

GPForum::Infrastructure::Id - Identifier service.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $id = GPForum::Infrastructure::Id->new->uuid;

=head1 DESCRIPTION

Provides UUID generation behind a replaceable service boundary.
L<Crypt::URandom> is loaded when minting a UUID so compile-time tests can
inject L<GPForum::Test::Id> without that XS module.

=head1 SUBROUTINES/METHODS

=head2 uuid_pattern

The pattern a uuid's text form matches.

=head2 is_uuid

True when a value has the shape of a uuid.

=head2 uuid

Returns a version-seven UUID string.

=head1 DIAGNOSTICS

Random byte generation errors are surfaced by L<Crypt::URandom>.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables are read.

=head1 DEPENDENCIES

Uses L<Crypt::URandom>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Only UUID version seven generation is exposed.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
