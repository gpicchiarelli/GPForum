# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Infrastructure::Antivirus;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Antivirus::Clamd;
use GPForum::Infrastructure::Antivirus::Command;
use GPForum::OS;

our $VERSION = '0.001';

# ADR 0108: uploads are scanned by the free antivirus the operating system's
# package manager installed. GPForum installs and bundles none of it. This
# picks the scanner the configuration names, with the clamd socket the OS
# package declares unless GPFORUM_ANTIVIRUS_SOCKET says otherwise. Undef means
# the operator turned scanning off: uploads are then checked for format only,
# and recorded as such.
sub from_config ( $class, $config, $os = undef ) {
    my $engine = $config->antivirus;
    return if $engine eq 'none';

    if ( $engine eq 'command' ) {
        return GPForum::Infrastructure::Antivirus::Command->new(
            command         => $config->antivirus_command,
            timeout_seconds => $config->antivirus_timeout_seconds,
        );
    }

    return GPForum::Infrastructure::Antivirus::Clamd->new(
        socket_path     => $class->socket_for( $config, $os ),
        timeout_seconds => $config->antivirus_timeout_seconds,
    );
}

# Undef on an operating system with no packaged default and no socket set.
# Not an exception: the scanner is built anyway and every scan of it is an
# error verdict naming the fix, so uploads wait unserved and readiness is
# degraded -- rather than every helper that builds it dying, and with them the
# outbox and the readiness endpoint.
sub socket_for ( $class, $config, $os = undef ) {
    my $configured = $config->antivirus_socket;
    return $configured if defined $configured && length $configured;

    return ( $os || GPForum::OS->detect )->antivirus_packaging->{socket};
}

1;

__END__

=head1 NAME

GPForum::Infrastructure::Antivirus - The upload scanner the system provides.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $scanner = GPForum::Infrastructure::Antivirus->from_config($config);
    my $verdict = $scanner ? $scanner->scan($bytes) : undef;

=head1 DESCRIPTION

Builds the scanner C<GPFORUM_ANTIVIRUS> names: a client for the operating
system's clamd, or a scanner command the system installed. Returns undef for
C<none>. See ADR 0108.

=head1 SUBROUTINES/METHODS

=head2 from_config

The scanner for a L<GPForum::Config>, or undef when scanning is off.

=head2 socket_for

The clamd socket: C<GPFORUM_ANTIVIRUS_SOCKET>, or the one the operating
system's package declares (L<GPForum::OS::Base/antivirus_packaging>); undef
when neither exists.

=head1 DIAGNOSTICS

Never dies. On an operating system with no packaged default and no socket
configured, the clamd scanner has no socket and every scan is an error
verdict asking for C<GPFORUM_ANTIVIRUS_SOCKET>.

=head1 CONFIGURATION AND ENVIRONMENT

C<GPFORUM_ANTIVIRUS>, C<GPFORUM_ANTIVIRUS_SOCKET>,
C<GPFORUM_ANTIVIRUS_COMMAND>, C<GPFORUM_ANTIVIRUS_TIMEOUT_SECONDS>.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::Antivirus::Clamd>,
L<GPForum::Infrastructure::Antivirus::Command>, L<GPForum::OS>.

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
