package GPForum::Service::SessionToken;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use Mojo::Base -base;

our $VERSION = '0.001';

const my $TOKEN_BYTES => 32;

sub issue_token {
    my ($self) = @_;

    return unpack 'H*', _random_bytes($TOKEN_BYTES);
}

sub hash_token {
    my ( $self, $token ) = @_;

    return sha256_hex($token);
}

sub _random_bytes {
    my ($bytes) = @_;

    require Crypt::URandom;
    return Crypt::URandom::urandom($bytes);
}

1;

__END__

=head1 NAME

GPForum::Service::SessionToken - Raw session token issuer and hasher.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $token = GPForum::Service::SessionToken->new->issue_token;

=head1 DESCRIPTION

Issues cryptographically random raw session tokens and hashes them before
persistence. Raw tokens are intended for cookies only. L<Crypt::URandom> is
loaded when issuing a token so compile-time tests can inject
L<GPForum::Test::SessionToken> without that XS module.

=head1 SUBROUTINES/METHODS

=head2 issue_token

Returns a random hex-encoded session token.

=head2 hash_token

Returns a SHA-256 hexadecimal digest for a raw session token.

=head1 DIAGNOSTICS

Randomness failures are reported by L<Crypt::URandom>.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables are read.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Crypt::URandom>, L<Digest::SHA>, and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Token rotation and persistence workflows are implemented by identity services.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
