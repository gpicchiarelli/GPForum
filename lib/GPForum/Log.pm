# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Log;

use Mojo::Base -strict, -signatures;
use v5.40;

use GPForum::X::Config;

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
    my $path = $config->log_path;
    if ( !defined $path || !length $path ) {
        return;
    }

    # Mojo::Log opens the file on first use and dies with its own words when
    # it cannot: open it now, so a bad path stops the start, not a request.
    $app->log->path($path);
    try {
        $app->log->handle;
    }
    catch ($error) {
        GPForum::X::Config->throw(
            message => "unable to open the configured log path: $path",
            cause   => $error,
        );
    };

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

Throws L<GPForum::X::Config> when the configured C<log_path> cannot be
opened, with the opening error as its C<cause>.

=head1 CONFIGURATION AND ENVIRONMENT

Receives log level through L<GPForum::Config>.

=head1 DEPENDENCIES

Uses L<Mojo::Base> and L<GPForum::X::Config>.

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
