# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RoutelessController;

use Carp qw(croak);
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

has telemetry => sub { croak 'RoutelessController requires telemetry' };

# A controller built outside a request: asking for its route dies.
sub current_route ($self) {
    croak 'no current_route helper outside a request';
}

sub gp_security_telemetry ($self) {
    return $self->telemetry;
}

1;

__END__

=head1 NAME

GPForum::Test::RoutelessController - A controller with no route to name.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $controller = GPForum::Test::RoutelessController->new(
        telemetry => GPForum::Service::Operations::SecurityTelemetry->new );

=head1 DESCRIPTION

Stands in for a controller built outside a request, whose C<current_route>
dies, so L<GPForum::Web::SecurityEvent> has to record the route as
C<unknown>.

=head1 SUBROUTINES/METHODS

=head2 telemetry

The security telemetry C<gp_security_telemetry> answers with.

=head2 current_route

Croaks.

=head2 gp_security_telemetry

Returns C<telemetry>.

=head1 DIAGNOSTICS

C<current_route> always croaks.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Carp>, L<Mojo::Base>.

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
