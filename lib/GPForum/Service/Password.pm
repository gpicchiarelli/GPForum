package GPForum::Service::Password;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Crypt::Argon2 qw(argon2id_pass argon2id_verify);
use Mojo::Base -base;

our $VERSION = '0.001';

const my $SALT_BYTES     => 16;
const my $TIME_COST      => 3;
const my $MEMORY_COST    => '32M';
const my $PARALLELISM    => 1;
const my $TAG_BYTES      => 32;
const my $MINIMUM_LENGTH => 12;

sub hash_password {
    my ( $self, $password ) = @_;

    _require_password($password);

    return argon2id_pass( $password, _random_bytes($SALT_BYTES),
        $TIME_COST, $MEMORY_COST, $PARALLELISM, $TAG_BYTES );
}

sub verify_password {
    my ( $self, $password, $encoded_hash ) = @_;

    return 0 if !defined $password;
    return 0 if !defined $encoded_hash;
    return 0 if $encoded_hash !~ /\A \x{24} argon2id \x{24} /msx;

    return argon2id_verify( $encoded_hash, $password ) ? 1 : 0;
}

sub _require_password {
    my ($password) = @_;

    croak 'password is required'
      if !defined $password || !length $password;

    croak "password must be at least $MINIMUM_LENGTH characters"
      if length $password < $MINIMUM_LENGTH;

    return;
}

sub _random_bytes {
    my ($bytes) = @_;

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
