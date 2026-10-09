# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::DeadLetterCheck::ProbeId;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

has counter => 0;

sub uuid ($self) {
    $self->counter( $self->counter + 1 );

    return sprintf 'dead-letter-id-%d', $self->counter;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::DeadLetterCheck::ProbeId - The dead-letter check's ids, counted.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # Built by GPForum::Service::Operations::DeadLetterCheck for its
    # simulate mode; nothing else uses it.
    my $probe = GPForum::Service::Operations::DeadLetterCheck::ProbeId->new;

=head1 DESCRIPTION

Ids that say where they came from: C<dead-letter-id-1>, C<dead-letter-id-2>, and so on. One of the in-memory stand-ins
L<GPForum::Service::Operations::DeadLetterCheck> runs the real
L<GPForum::Service::Outbox::Dispatcher> against in its C<simulate> mode.

=head1 SUBROUTINES/METHODS

=head2 uuid

Returns C<dead-letter-id-1>, C<dead-letter-id-2>, and so on.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None beyond L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

It stands in for PostgreSQL only as far as the dead-letter check needs.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
