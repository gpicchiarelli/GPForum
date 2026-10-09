# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SkewedClock;

use Mojo::Base 'GPForum::Service::Clock', -signatures;
use v5.40;

our $VERSION = '0.001';

has seconds => 0;    # how far ahead of the system clock; negative is behind

# The application's clock on a host whose clock is not this one's, or on
# this host a whole second later: a store given it stamps its rows that many
# seconds away from the stores that read the system clock.
sub now_epoch ($self) {
    return $self->SUPER::now_epoch + $self->seconds;
}

1;

__END__

=head1 NAME

GPForum::Test::SkewedClock - The application clock, a fixed number of seconds ahead or behind.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $ahead = GPForum::Test::SkewedClock->new( seconds => 2 );

=head1 DESCRIPTION

A L<GPForum::Service::Clock> that runs C<seconds> away from the system
clock. A race test gives it to one side so that side's timestamps fall in a
later (or earlier) second than the other side's, whenever the test runs,
instead of only when a second boundary happens to fall between them.

=head1 SUBROUTINES/METHODS

=head2 now_epoch

The system clock's epoch plus C<seconds>. C<now_iso8601> and
C<epoch_plus_iso8601> follow it.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Clock>.

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
