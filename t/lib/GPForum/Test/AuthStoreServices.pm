package GPForum::Test::AuthStoreServices;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has credentials => sub { return {}; };
has sessions    => sub { return []; };

sub verify_password {
    my ( undef, $password, $hash ) = @_;

    if ( !defined $password || !defined $hash ) {
        return 0;
    }

    return $hash eq ( 'hashed:' . $password ) ? 1 : 0;
}

sub active_password_credential {
    my ( $self, $user_id ) = @_;

    return $self->credentials->{$user_id};
}

sub create_session {
    my ( $self, $user, $input ) = @_;

    my $session = { session_id => 'sess-1' };
    push @{ $self->sessions },
      {
        input   => $input,
        session => $session,
        user    => $user,
      };

    return { session => $session };
}

1;

__END__

=head1 NAME

GPForum::Test::AuthStoreServices - Identity auth-store fakes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $services = GPForum::Test::AuthStoreServices->new;

=head1 DESCRIPTION

Test double for password verification, credential lookup, and session creation
used by C<Identity::AuthStore>.

=head1 SUBROUTINES/METHODS

=head2 verify_password

Compares a password against a deterministic fake hash.

=head2 active_password_credential

Returns the stored credential for a user id.

=head2 create_session

Records the login command and returns a fixed session id.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not emulate session expiry or revocation.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
