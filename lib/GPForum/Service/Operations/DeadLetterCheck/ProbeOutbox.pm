# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::DeadLetterCheck::ProbeOutbox;

use List::Util qw(any);
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

has rows => sub { return []; };

sub search_rs ( $self, $query, $attrs ) {
    my @matched = grep { _row_matches( $_, $query ) } @{ $self->rows };
    my $limit   = $attrs->{rows};
    if ( defined $limit && $limit < @matched ) {
        @matched = @matched[ 0 .. $limit - 1 ];
    }

    return ( ref $self )->new( rows => \@matched );
}

# DBIx::Class's resultset method name.
sub all ($self) {
    return @{ $self->rows };
}

sub _row_matches ( $row, $query ) {
    if ( !defined $query ) {
        return 1;
    }
    if ( ref $query eq 'ARRAY' ) {
        return ( any { _row_matches( $row, $_ ) } @{$query} ) ? 1 : 0;
    }

    for my $column ( keys %{$query} ) {
        if ( !_column_matches( $row->get_column($column), $query->{$column} ) )
        {
            return 0;
        }
    }

    return 1;
}

# Equality, -in, and <= compared as strings: what the dispatcher's claim
# query asks of the outbox.
sub _column_matches ( $actual, $expected ) {
    if ( ref $expected eq 'HASH' && exists $expected->{-in} ) {
        return any { $_ eq ( $actual // q{} ) } @{ $expected->{-in} };
    }
    if ( ref $expected eq 'HASH' && exists $expected->{'<='} ) {
        return defined $actual && $actual le $expected->{'<='};
    }

    return ( $actual // q{} ) eq ( $expected // q{} );
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::DeadLetterCheck::ProbeOutbox - The dead-letter check's outbox, held in memory.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # Built by GPForum::Service::Operations::DeadLetterCheck for its
    # simulate mode; nothing else uses it.
    my $probe = GPForum::Service::Operations::DeadLetterCheck::ProbeOutbox->new;

=head1 DESCRIPTION

Rows and the searches over them: C<search_rs> returns another C<ProbeOutbox> holding the rows that match, which C<all> lists. One of the in-memory stand-ins
L<GPForum::Service::Operations::DeadLetterCheck> runs the real
L<GPForum::Service::Outbox::Dispatcher> against in its C<simulate> mode.

=head1 SUBROUTINES/METHODS

=head2 search_rs

Takes a condition and attributes and returns a C<ProbeOutbox> of the rows that match, at most C<< $attrs->{rows} >> of them. It understands only what the dispatcher's claim query uses: equality, C<-in>, C<< <= >> (as a string comparison) and an array reference of alternatives. C<order_by> is ignored.

=head2 all

Returns the rows as a list.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<List::Util>.

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
