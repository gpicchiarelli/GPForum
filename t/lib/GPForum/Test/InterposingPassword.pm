# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::InterposingPassword;

use Mojo::Base 'GPForum::Service::Password', -signatures;
use v5.40;

our $VERSION = '0.001';

has interpose => undef;    # optional: without it this is the password service

# The next password that verifies runs the code first, once: whatever it does
# happens between a login's verification and the session it then opens.
sub verify_password ( $self, $password, $encoded_hash ) {
    my $verified = $self->SUPER::verify_password( $password, $encoded_hash );
    my $code     = $self->interpose;
    if ( $verified && $code ) {
        $self->interpose(undef);
        $code->();
    }

    return $verified;
}

1;

__END__

=head1 NAME

GPForum::Test::InterposingPassword - The password service, running code right after a password verifies.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $password = GPForum::Test::InterposingPassword->new(
        interpose => sub { $rival->reset_password($input) },
    );
    $store->authenticate_login( { identifier => $name, password => $text } );

=head1 DESCRIPTION

A L<GPForum::Service::Password> whose C<verify_password>, the first time a
password verifies, runs C<interpose> before it answers. A race test uses it
to commit a concurrent write between a login's Argon2 verification and the
session the login opens.

=head1 SUBROUTINES/METHODS

=head2 verify_password

Verifies as the service does; on the first success runs C<interpose> once.

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
