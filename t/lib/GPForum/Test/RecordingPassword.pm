# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RecordingPassword;

use Mojo::Base 'GPForum::Service::Password';
use v5.40;

our $VERSION = '0.001';

# The real Argon2 service, which also notes every hash a password was checked
# against: a login for an account that does not exist has to verify against
# the decoy, and the answer alone cannot show whether it did.
has verified => sub { return []; };

sub verify_password {
    my ( $self, $password, $encoded_hash ) = @_;

    push @{ $self->verified }, $encoded_hash;

    return $self->SUPER::verify_password( $password, $encoded_hash );
}

1;

__END__

=head1 NAME

GPForum::Test::RecordingPassword - The password service, recording each hash it verifies against.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $password = GPForum::Test::RecordingPassword->new;
    $store->authenticate_login( { identifier => 'nobody', password => $text } );
    is( $password->verified->[-1], $password->decoy_hash );

=head1 DESCRIPTION

A L<GPForum::Service::Password> whose C<verify_password> first appends the
hash it was given to C<verified>, then verifies as the service does.

=head1 SUBROUTINES/METHODS

=head2 verify_password

Records the hash, then verifies the password against it.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Password>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
