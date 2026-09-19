package GPForum::Test::RegistrationStoreServices;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has credentials   => sub { return []; };
has registrations => sub { return []; };
has value         => 0;

sub create_password_credential {
    my ( $self, $input ) = @_;

    push @{ $self->credentials }, $input;

    return 1;
}

sub record_registration {
    my ( $self, $user, $correlation_id ) = @_;

    push @{ $self->registrations },
      {
        correlation_id => $correlation_id,
        user           => $user,
      };

    return;
}

sub uuid {
    my ($self) = @_;

    $self->value( $self->value + 1 );

    return 'generated-' . $self->value;
}

1;

__END__

=head1 NAME

GPForum::Test::RegistrationStoreServices - Registration-store fakes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $services = GPForum::Test::RegistrationStoreServices->new;

=head1 DESCRIPTION

Test double for credential creation, registration audit, and id allocation
used by C<Identity::RegistrationStore>.

=head1 SUBROUTINES/METHODS

=head2 create_password_credential

Records the credential command.

=head2 record_registration

Records the audit command.

=head2 uuid

Returns a deterministic generated id.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not emulate database uniqueness constraints.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
