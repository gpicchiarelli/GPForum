# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SearchResult;

use Carp qw(carp croak);
use Mojo::Base -base;
use v5.40;

use GPForum::Test::Query;
use GPForum::Test::ResultSetColumn;

our $VERSION = '0.001';

has position => 0;
has rows     => sub { return []; };

# all, next and reset read as builtins to Perl::Critic, so the methods carry
# longer names and DBIx::Class's are aliases.
BEGIN {
    *all   = \&all_rows;
    *next  = \&next_row;
    *reset = \&reset_cursor;
}

sub all_rows {
    my ($self) = @_;

    return @{ $self->rows };
}

sub count {
    my ($self) = @_;

    return scalar @{ $self->rows };
}

# DBIx::Class's single: the one row, or undef when none matched. It reads
# only the first row and warns when the statement returned more, because a
# caller that expected one row and got several has a query that is not
# unique.
sub single {
    my ( $self, @condition ) = @_;

    croak 'single() only takes search conditions, no attributes. '
      . 'You want ->search( $cond, $attrs )->single()'
      if @condition > 1;

    my @rows = $self->_matching( $condition[0] );
    return undef if !@rows;

    carp 'Query returned more than one row.  SQL that returns multiple rows '
      . 'is DEPRECATED for ->find and ->single'
      if @rows > 1;

    return $rows[0];
}

sub first {
    my ($self) = @_;

    $self->reset_cursor;

    return $self->next_row;
}

sub next_row {
    my ($self) = @_;

    my $position = $self->position;
    return undef if $position > $#{ $self->rows };

    $self->position( $position + 1 );

    return $self->rows->[$position];
}

sub reset_cursor {
    my ($self) = @_;

    $self->position(0);

    return $self;
}

sub get_column {
    my ( $self, $column ) = @_;

    my $field = GPForum::Test::Query::column_field($column);

    return GPForum::Test::ResultSetColumn->new(
        values => [ map { column_value( $_, $field ) } @{ $self->rows } ] );
}

# A search of a search narrows it, keeping every other attribute of the
# double; the condition, order and window are read as Test::Query reads them.
sub search_rs {
    my ( $self, $condition, $attributes ) = @_;

    my @rows = $self->_matching($condition);
    @rows =
      GPForum::Test::Query::ordered_rows( \@rows, $attributes, \&column_value );
    @rows = GPForum::Test::Query::windowed_rows( \@rows, $attributes );

    return ref($self)->new( %{$self}, position => 0, rows => \@rows );
}

# DBIx::Class's search returns the rows in list context and the resultset
# otherwise; search_rs is the context-proof form lib/ calls.
sub search {
    my ( $self, @arguments ) = @_;

    my $search = $self->search_rs(@arguments);

    return wantarray ? $search->all_rows : $search;
}

# A row is a hash or a row object; either way the column is read the way the
# application reads it.
sub column_value {
    my ( $row, $column ) = @_;

    return undef           if !defined $row;
    return $row->{$column} if ref $row eq 'HASH';

    return $row->get_column($column);
}

sub _matching {
    my ( $self, $condition ) = @_;

    return @{ $self->rows } if !defined $condition;

    return
      grep { GPForum::Test::Query::matches( $_, $condition, \&column_value ) }
      @{ $self->rows };
}

1;

__END__

=head1 NAME

GPForum::Test::SearchResult - Base for what a fake resultset's search returns.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    package GPForum::Test::ThingSearch;
    use Mojo::Base 'GPForum::Test::SearchResult';

    my $search = GPForum::Test::ThingSearch->new( rows => \@rows );
    my @rows   = $search->all;
    my $row    = $search->single;    # undef, the row, or the first and a warning
    my $ids    = $search->get_column('thing_id');

=head1 DESCRIPTION

The DBIx::Class resultset surface the application reads from a search, over
the rows the fake matched: C<all>, C<count>, C<single>, C<first>, C<next>,
C<reset>, C<get_column>, and C<search>/C<search_rs> to narrow it. C<rows>
stays the array the rows live in, so a test can build or inspect one.

C<single> follows DBIx::Class: undef when no row matched, the row when one
did, and the first row with DBIx::Class's warning when several did -- the
warning is how a query that is not unique shows up in the unit tier.

=head1 SUBROUTINES/METHODS

=head2 all_rows

Every row. Also C<all>.

=head2 count

How many rows matched.

=head2 single

One row or undef, warning when several matched. Croaks when given
attributes, as DBIx::Class does.

=head2 first

The first row, rewinding the cursor first.

=head2 next_row

The next row, or undef at the end. Also C<next>.

=head2 reset_cursor

Rewinds the cursor. Also C<reset>.

=head2 get_column

A L<GPForum::Test::ResultSetColumn> over one column.

=head2 search_rs

A narrower search of the same class.

=head2 search

The rows in list context, as DBIx::Class gives them; otherwise the same as
C<search_rs>.

=head2 column_value

Reads a column from a hash or a row object.

=head1 DIAGNOSTICS

C<single> warns C<Query returned more than one row> and croaks when passed
attributes, worded as DBIx::Class words both.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>, L<Carp>, L<GPForum::Test::Query>,
L<GPForum::Test::ResultSetColumn>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The operators are the ones L<GPForum::Test::Query> models.

=head1 AUTHOR

Giacomo Picchiarelli

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Giacomo Picchiarelli. BSD-3-Clause.

=cut
