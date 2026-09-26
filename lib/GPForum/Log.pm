# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Log;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -strict, -signatures;

our $VERSION = '0.001';

sub configure ( $class, $app, $config ) {
    $app->log->level( $config->log_level );
    $class->_apply_destination( $app, $config );
    $app->log->debug('GPForum logging configured');

    return;
}

# Mojolicious logs to STDERR by default, and Mojo::Server::daemonize reopens
# STDERR on /dev/null before Hypnotoad forks its workers. Setting only the level
# therefore meant every line of a daemonized deployment was discarded: no
# request log, no error, nothing to read during an incident.
#
# An explicit path takes the logger off STDERR so the destination survives
# daemonization. Leaving it empty keeps STDERR, which is correct when the
# process stays in the foreground and a supervisor captures it.
sub _apply_destination ( $, $app, $config ) {
    if ( !$config->can('log_path') ) {
        return;
    }

    my $path = $config->log_path;
    if ( !defined $path || !length $path ) {
        return;
    }

    $app->log->path($path);
    if ( !$app->log->handle ) {
        croak "unable to open the configured log path: $path";
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Log - Logging bootstrap.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    GPForum::Log->configure($app, $config);

=head1 DESCRIPTION

Configures the Mojolicious logger for the current runtime environment.

=head1 SUBROUTINES/METHODS

=head2 configure

Applies the configured log level, and the configured destination when
C<log_path> is set.

=head2 _apply_destination

Points the logger at C<log_path> when one is configured. Without it the logger
stays on STDERR, which Hypnotoad reopens on F</dev/null> when it daemonizes.

=head1 DIAGNOSTICS

This module does not throw its own exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

Receives log level through L<GPForum::Config>.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Only the default Mojolicious logger is configured in milestone zero.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
