# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::DeadLetterCheck::ProbeRow;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

has data    => sub { return {}; };
has updates => sub { return []; };

sub update ( $self, $changes ) {
    push @{ $self->updates }, $changes;
    for my $key ( keys %{$changes} ) {
        $self->data->{$key} = $changes->{$key};
    }

    return $self;
}

sub get_column ( $self, $column ) {
    return $self->data->{$column};
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::DeadLetterCheck::ProbeRow - An outbox row of the dead-letter check, held in memory.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # Built by GPForum::Service::Operations::DeadLetterCheck for its
    # simulate mode; nothing else uses it.
    my $probe = GPForum::Service::Operations::DeadLetterCheck::ProbeRow->new;

=head1 DESCRIPTION

The one row the check's outbox holds: its columns in C<data>, every update recorded in C<updates>. One of the in-memory stand-ins
L<GPForum::Service::Operations::DeadLetterCheck> runs the real
L<GPForum::Service::Outbox::Dispatcher> against in its C<simulate> mode.

=head1 SUBROUTINES/METHODS

=head2 update

Records the changes in C<updates>, applies them to C<data>, and returns the row.

=head2 get_column

Returns the column's value from C<data>.

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
