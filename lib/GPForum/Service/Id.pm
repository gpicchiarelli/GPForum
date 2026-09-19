package GPForum::Service::Id;

use strict;
use warnings;

use Mojo::Base -base;

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

sub uuid {
    my ($self) = @_;

    my $timestamp_ms = int( time * $MILLISECONDS );
    my @bytes = map { ( $timestamp_ms >> $_ ) & $BYTE_MASK } @TIMESTAMP_SHIFTS;

    push @bytes, unpack 'C*', _random_bytes($UUID_RANDOM_BYTES);

    $bytes[$VERSION_BYTE_INDEX] =
      ( $bytes[$VERSION_BYTE_INDEX] & $VERSION_MASK ) | $VERSION_SEVEN;
    $bytes[$VARIANT_BYTE_INDEX] =
      ( $bytes[$VARIANT_BYTE_INDEX] & $VARIANT_MASK ) | $VARIANT_RFC4122;

    return $self->_format_uuid_bytes( \@bytes );
}

sub _format_uuid_bytes {
    my ( $self, $bytes ) = @_;

    my $hex    = unpack 'H*', pack 'C*', @{$bytes};
    my @chunks = ();
    my $offset = 0;

    for my $length (@UUID_CHUNK_LENGTHS) {
        push @chunks, substr $hex, $offset, $length;
        $offset += $length;
    }

    return join q{-}, @chunks;
}

sub _random_bytes {
    my ($bytes) = @_;

    require Crypt::URandom;
    return Crypt::URandom::urandom($bytes);
}

1;

__END__

=head1 NAME

GPForum::Service::Id - Identifier service.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $id = GPForum::Service::Id->new->uuid;

=head1 DESCRIPTION

Provides UUID generation behind a replaceable service boundary.
L<Crypt::URandom> is loaded when minting a UUID so compile-time tests can
inject L<GPForum::Test::Id> without that XS module.

=head1 SUBROUTINES/METHODS

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
