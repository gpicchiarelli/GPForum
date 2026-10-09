# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::UniqueKey;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use List::Util   qw(any);
use Mojo::Loader qw(load_class);

our $VERSION = '0.001';

# DBIx::Class tries the primary key first, then the other keys by name.
const my $PRIMARY_FIRST => -1;
const my $PRIMARY_LAST  => 1;

# The condition DBIx::Class's find sends for a result class, as a list of
# alternatives a row must match one of.
#
# find takes a hash of column values, or primary key values in order, and an
# optional { key => $constraint }. With a key it keeps only that constraint's
# columns and refuses a condition that does not give them all. Without one it
# keeps, for every unique constraint the condition fully gives (the primary
# key first), only that constraint's columns, and ORs them; the other columns
# are dropped. Only when no constraint is fully given does it search on the
# whole condition. A fake find that matched every column it was given hid a
# store that looked a session up by its id and the member's: DBIx::Class read
# the id alone.
sub find_conditions {
    my ( $result_class, @arguments ) = @_;

    my $attributes =
      @arguments > 1 && ref $arguments[-1] eq 'HASH' ? pop @arguments : {};
    my $source = _source($result_class);

    if ( ref $arguments[0] ne 'HASH' ) {
        return [ _by_values( $source, $attributes->{key}, @arguments ) ];
    }

    my %condition = %{ $arguments[0] };
    if ( exists $attributes->{key} ) {
        return [ _satisfying( $source, $attributes->{key}, \%condition ) ];
    }

    my @alternatives = _every_satisfied( $source, \%condition );

    return @alternatives ? \@alternatives : [ \%condition ];
}

# True when the row matches one of the alternatives find_conditions gave.
sub matches {
    my ( $row, $alternatives ) = @_;

    for my $alternative ( @{$alternatives} ) {
        return 1 if _matches_all( $row, $alternative );
    }

    return 0;
}

sub _by_values {
    my ( $source, $key, @values ) = @_;

    my $name    = $key // 'primary';
    my @columns = $source->unique_constraint_columns($name);
    croak "No constraint columns, maybe a malformed '$name' constraint?"
      if !@columns;
    croak 'find() expects either a column/value hashref, or a list of values '
      . "corresponding to the columns of the specified unique constraint '$name'"
      if @columns != @values;

    my %condition;
    @condition{@columns} = @values;

    return \%condition;
}

sub _satisfying {
    my ( $source, $name, $condition ) = @_;

    croak q{An undefined 'key' resultset attribute makes no sense}
      if !defined $name;

    my @columns = $source->unique_constraint_columns($name);
    my @missing = sort grep { !exists $condition->{$_} } @columns;
    croak sprintf
q{Unable to satisfy requested constraint '%s', missing values for column(s): %s},
      $name, join q{, }, map { "'$_'" } @missing
      if @missing;

    return { map { $_ => $condition->{$_} } @columns };
}

sub _every_satisfied {
    my ( $source, $condition ) = @_;

    my ( @alternatives, %seen );
    for my $name ( _constraint_names($source) ) {
        my @columns = $source->unique_constraint_columns($name);
        next if $seen{ join q{,}, sort @columns }++;
        next
          if any { !defined $condition->{$_} || ref $condition->{$_} } @columns;
        push @alternatives, { map { $_ => $condition->{$_} } @columns };
    }

    return @alternatives;
}

sub _constraint_names {
    my ($source) = @_;

    my @names = sort {
            $a eq 'primary' ? $PRIMARY_FIRST
          : $b eq 'primary' ? $PRIMARY_LAST
          : $a cmp $b
    } $source->unique_constraint_names;

    return @names;
}

sub _matches_all {
    my ( $row, $condition ) = @_;

    for my $column ( keys %{$condition} ) {
        my $actual   = _column( $row, $column );
        my $expected = $condition->{$column};
        return 0 if defined $actual ne defined $expected;
        return 0 if defined $actual && $actual ne $expected;
    }

    return 1;
}

sub _column {
    my ( $row, $column ) = @_;

    return undef           if !defined $row;
    return $row->{$column} if ref $row eq 'HASH';

    return $row->get_column($column);
}

sub _source {
    my ($result_class) = @_;

    my $error = load_class($result_class);
    croak "cannot load $result_class: $error" if ref $error;
    croak "cannot load $result_class"         if $error;

    return $result_class->result_source_instance;
}

1;

__END__

=head1 NAME

GPForum::Test::UniqueKey - The condition DBIx::Class's find really sends.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $alternatives = GPForum::Test::UniqueKey::find_conditions(
        'GPForum::Schema::Result::Session',
        { session_id => $id, user_id => $member },
    );
    # [ { session_id => $id } ] -- user_id is not part of a unique key

    my ($row) = grep { GPForum::Test::UniqueKey::matches( $_, $alternatives ) }
      @rows;

=head1 DESCRIPTION

A fake resultset's C<find> reads the result class's real primary key and
unique constraints through this module, so it narrows the condition the way
L<DBIx::Class::ResultSet/find> does instead of matching every column it was
given.

=head1 SUBROUTINES/METHODS

=head2 find_conditions

Given a result class and C<find>'s arguments, the alternatives a row must
match one of: the columns of each fully given unique constraint, the named
constraint's columns with C<key>, the primary key's columns for a list of
values, or the whole condition when no constraint is fully given.

=head2 matches

True when a hash or row object matches one of the alternatives.

=head1 DIAGNOSTICS

Croaks with DBIx::Class's wording on a C<key> whose columns are not all given,
on an undefined C<key>, and on a list of values that does not fit the
constraint.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Carp>, L<Const::Fast>, L<List::Util>, L<Mojo::Loader>, the C<GPForum::Schema::Result> classes.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Relationship values in the condition and the resultset's own search condition
are not merged in; the doubles do not call find on a narrowed search.

=head1 AUTHOR

Giacomo Picchiarelli

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Giacomo Picchiarelli. BSD-3-Clause.

=cut
