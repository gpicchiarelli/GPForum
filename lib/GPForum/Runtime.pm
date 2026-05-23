package GPForum::Runtime;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has web_processes      => 1;
has worker_processes   => 1;
has realtime_processes => 1;

sub from_config {
    my ( $class, $config ) = @_;

    return $class->new(
        web_processes      => $config->web_processes,
        worker_processes   => $config->worker_processes,
        realtime_processes => $config->realtime_processes,
    );
}

sub as_hash {
    my ($self) = @_;

    return {
        web_processes      => $self->web_processes,
        worker_processes   => $self->worker_processes,
        realtime_processes => $self->realtime_processes,
    };
}

1;

__END__

=head1 NAME

GPForum::Runtime - Runtime process profile.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $runtime = GPForum::Runtime->from_config($config);

=head1 DESCRIPTION

Carries process-count settings for the GPForum multi-process runtime model.

=head1 SUBROUTINES/METHODS

=head2 from_config

Creates a runtime profile from configuration.

=head2 as_hash

Returns the profile as a plain hash reference.

=head1 DIAGNOSTICS

This module does not throw its own exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

Receives validated process counts from L<GPForum::Config>.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

This profile is descriptive; process supervision is implemented outside this
module.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
