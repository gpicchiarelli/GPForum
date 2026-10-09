# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::DeadLetterCheck::ProbeLetters;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

has created => sub { return []; };
has rows    => sub { return {}; };

sub create ( $self, $row ) {
    $self->rows->{ _key($row) } = $row;
    push @{ $self->created }, $row;

    return $row;
}

sub find ( $self, $query ) {
    return $self->rows->{ _key($query) };
}

sub purge_older_than ( $self, $cutoff ) {
    my @kept;
    my $purged = 0;
    for my $row ( @{ $self->created } ) {
        my $stamp = $row->{last_failed_at} // q{};
        if ( length $stamp && $stamp lt $cutoff ) {
            $purged++;
            next;
        }
        push @kept, $row;
    }
    $self->created( \@kept );
    $self->rows( { map { ( _key($_) => $_ ) } @kept } );

    return $purged;
}

sub _key ($row) {
    return join q{:}, $row->{source_table} // q{}, $row->{source_id} // q{};
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::DeadLetterCheck::ProbeLetters - The dead-letter check's dead-letter store, held in memory.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # Built by GPForum::Service::Operations::DeadLetterCheck for its
    # simulate mode; nothing else uses it.
    my $probe = GPForum::Service::Operations::DeadLetterCheck::ProbeLetters->new;

=head1 DESCRIPTION

Dead letters keyed by their C<source_table> and C<source_id>, and the list of those created. One of the in-memory stand-ins
L<GPForum::Service::Operations::DeadLetterCheck> runs the real
L<GPForum::Service::Outbox::Dispatcher> against in its C<simulate> mode.

=head1 SUBROUTINES/METHODS

=head2 create

Stores a dead-letter row under its C<source_table> and C<source_id>, appends it to C<created>, and returns it.

=head2 find

Returns the row stored for a C<source_table> and C<source_id>, or C<undef>.

=head2 purge_older_than

Removes the rows whose C<last_failed_at> is set and sorts before the cutoff, and returns how many it removed.

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
