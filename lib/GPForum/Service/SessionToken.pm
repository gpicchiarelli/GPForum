# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::SessionToken;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $TOKEN_BYTES => 32;

sub issue_token ($self) {
    return unpack 'H*', _random_bytes($TOKEN_BYTES);
}

sub hash_token ( $self, $token ) {
    return sha256_hex($token);
}

sub _random_bytes ($bytes) {
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
persistence. The raw token goes into the signed session cookie and nowhere
else; the database keeps only its SHA-256, which
L<GPForum::Service::Identity::SessionStore/validate_session> compares on every
request.

That comparison is the point. The signed cookie already proves the browser
holds one this application issued; the token proves it holds the secret for
that particular session, so a forged or replayed cookie is not enough on its
own. This module previously issued tokens that were hashed into the row and
then discarded, which left the column authenticating nothing while this
paragraph claimed otherwise. L<Crypt::URandom> is
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
