# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ResultSetColumn;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base;
use v5.40;

use GPForum::Test::Query;

our $VERSION = '0.001';

const my %AGGREGATE => map { $_ => 1 } qw(count max min sum);

has position => 0;
has values   => sub { return []; };

BEGIN {
    *all   = \&all_values;
    *next  = \&next_value;
    *reset = \&reset_cursor;
}

sub all_values {
    my ($self) = @_;

    return @{ $self->values };
}

sub first {
    my ($self) = @_;

    $self->reset_cursor;

    return $self->next_value;
}

sub next_value {
    my ($self) = @_;

    my $position = $self->position;
    return undef if $position > $#{ $self->values };

    $self->position( $position + 1 );

    return $self->values->[$position];
}

sub reset_cursor {
    my ($self) = @_;

    $self->position(0);

    return $self;
}

# SQL aggregates skip NULL, and over no row at all MAX, MIN and SUM are NULL
# while COUNT is 0.
sub max {
    my ($self) = @_;

    return $self->_aggregate( sub { $_[0] > 0 } );
}

sub min {
    my ($self) = @_;

    return $self->_aggregate( sub { $_[0] < 0 } );
}

sub sum {
    my ($self) = @_;

    my @present = grep { defined } @{ $self->values };
    return undef if !@present;

    my $total = 0;
    for my $value (@present) {
        $total += $value;
    }

    return $total;
}

# DBIx::Class::ResultSetColumn has no count method: COUNT is reached through
# func, as the SQL aggregate that skips NULL. A double with its own count would
# let code call a method the real column does not answer.
sub func {
    my ( $self, $function ) = @_;

    my $name = lc $function;
    croak "unsupported test aggregate: $function"     if !$AGGREGATE{$name};
    return scalar grep { defined } @{ $self->values } if $name eq q{count};

    return $self->$name;
}

sub _aggregate {
    my ( $self, $keeps ) = @_;

    my $held;
    for my $value ( grep { defined } @{ $self->values } ) {
        if ( !defined $held
            || $keeps->( GPForum::Test::Query::compare_values( $value, $held ) )
          )
        {
            $held = $value;
        }
    }

    return $held;
}

1;

__END__

=head1 NAME

GPForum::Test::ResultSetColumn - What a fake resultset's get_column returns.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $column = $search->get_column('post_id');
    my @ids    = $column->all;
    my $newest = $column->max;

=head1 DESCRIPTION

Gives the values of one column across a fake search the methods of
L<DBIx::Class::ResultSetColumn> the application calls: the cursor (C<all>,
C<first>, C<next>, C<reset>) and the aggregates (C<max>, C<min>, C<sum>,
C<func>), with SQL's treatment of NULL. Like the real column it has no
C<count> method: C<func('COUNT')> counts the values that are not NULL.

=head1 SUBROUTINES/METHODS

=head2 all_values

Every value, in row order. Also C<all>.

=head2 first

The first value, rewinding the cursor first.

=head2 next_value

The next value, or undef at the end. Also C<next>.

=head2 reset_cursor

Rewinds the cursor. Also C<reset>.

=head2 max

The largest defined value, or undef.

=head2 min

The smallest defined value, or undef.

=head2 sum

The sum of the defined values, or undef when there is none.

=head2 func

One of the aggregates above by name, or C<COUNT>: how many values are
defined.

=head1 DIAGNOSTICS

C<func> croaks on an aggregate it does not model.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>, L<Carp>, L<Const::Fast>, L<GPForum::Test::Query>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

C<as_query> is not modelled; a double that a subquery reads defines its own.

=head1 AUTHOR

Giacomo Picchiarelli

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Giacomo Picchiarelli. BSD-3-Clause.

=cut
