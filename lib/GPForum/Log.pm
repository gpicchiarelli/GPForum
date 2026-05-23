package GPForum::Log;

use strict;
use warnings;

use Mojo::Base -strict;

our $VERSION = '0.001';

sub configure {
    my ( $class, $app, $config ) = @_;

    $app->log->level( $config->log_level );
    $app->log->debug('GPForum logging configured');

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

Applies the configured log level to the application logger.

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
