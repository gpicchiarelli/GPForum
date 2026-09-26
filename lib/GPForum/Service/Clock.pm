# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Clock;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use Time::Piece;

our $VERSION = '0.001';

sub now_epoch ($self) {
    return time;
}

sub now_iso8601 ($self) {
    return gmtime( $self->now_epoch )->datetime . 'Z';
}

sub epoch_plus_iso8601 ( $self, $seconds ) {
    return gmtime( $self->now_epoch + $seconds )->datetime . 'Z';
}

1;

__END__

=head1 NAME

GPForum::Service::Clock - Time service.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $timestamp = GPForum::Service::Clock->new->now_iso8601;

=head1 DESCRIPTION

Provides a replaceable clock boundary for tests and application workflows.

=head1 SUBROUTINES/METHODS

=head2 now_epoch

Returns the current epoch time.

=head2 now_iso8601

Returns the current UTC timestamp in ISO-8601 format.

=head1 DIAGNOSTICS

This module does not throw its own exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables are read.

=head1 DEPENDENCIES

Uses L<Time::Piece>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The service currently returns system time only.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
