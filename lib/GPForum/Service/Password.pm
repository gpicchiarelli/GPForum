# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Password;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Crypt::Argon2 qw(argon2id_pass argon2id_verify);
use Mojo::Base -base, -signatures;
use feature qw(state);

our $VERSION = '0.001';

const my $SALT_BYTES     => 16;
const my $TIME_COST      => 3;
const my $MEMORY_COST    => '32M';
const my $PARALLELISM    => 1;
const my $TAG_BYTES      => 32;
const my $MINIMUM_LENGTH => 12;

sub hash_password ( $self, $password ) {
    _require_password($password);

    return argon2id_pass( $password, _random_bytes($SALT_BYTES),
        $TIME_COST, $MEMORY_COST, $PARALLELISM, $TAG_BYTES );
}

sub verify_password ( $self, $password, $encoded_hash ) {
    return 0 if !defined $password;
    return 0 if !defined $encoded_hash;
    return 0 if $encoded_hash !~ /\A \x{24} argon2id \x{24} /msx;

    return argon2id_verify( $encoded_hash, $password ) ? 1 : 0;
}

# A hash nobody knows the password of, made once per process. A login for
# an unknown account verifies against it, so that it costs what a wrong
# password costs: answering at once told anyone timing the reply which
# usernames and addresses have an account.
sub decoy_hash ($self) {
    state $decoy = argon2id_pass(
        unpack( 'H*', _random_bytes($SALT_BYTES) ),
        _random_bytes($SALT_BYTES),
        $TIME_COST, $MEMORY_COST, $PARALLELISM, $TAG_BYTES
    );

    return $decoy;
}

sub _require_password ($password) {
    croak 'password is required'
      if !defined $password || !length $password;

    croak "password must be at least $MINIMUM_LENGTH characters"
      if length $password < $MINIMUM_LENGTH;

    return;
}

sub _random_bytes ($bytes) {
    require Crypt::URandom;
    return Crypt::URandom::urandom($bytes);
}

1;

__END__

=head1 NAME

GPForum::Service::Password - Argon2id password hashing boundary.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $hash = GPForum::Service::Password->new->hash_password($password);

=head1 DESCRIPTION

Provides the mandatory Argon2id password hashing and verification boundary for
identity workflows. L<Crypt::URandom> is loaded when hashing so compile-time
tests can inject collaborators without that XS module.

=head1 SUBROUTINES/METHODS

=head2 hash_password

Validates and hashes a password with Argon2id and a cryptographic random salt.

=head2 verify_password

Verifies a password against an encoded Argon2id hash.


=head2 decoy_hash

An Argon2id hash of a random password, made once per process, to verify
against when there is no account: an unknown login then takes as long as a
wrong password.

=head1 DIAGNOSTICS

Throws exceptions for missing or too-short passwords.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables are read.

=head1 DEPENDENCIES

Uses L<Carp>, L<Const::Fast>, L<Crypt::Argon2>, L<Crypt::URandom>, and
L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Argon2 parameters are fixed until calibration tooling is added.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
