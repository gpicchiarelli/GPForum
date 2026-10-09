# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RowState;

use v5.40;

use Const::Fast;
use Scalar::Util qw(blessed refaddr);

our $VERSION = '0.001';

# Where the fake resultsets keep their rows.
const my @ROW_SET_ACCESSOR => qw(created created_objects rows);

# A rollback in the doubles: what capture copies, restore puts back. Two
# things are copied, because a transaction undoes both: which rows a row set
# holds (an INSERT or a DELETE) and what each row holds (an UPDATE). Copying
# only the first put the same row objects back with every column change the
# failed attempt had made, so a test could not tell a rollback from a commit.
sub capture {
    my (@containers) = @_;

    return {
        rows => capture_rows(@containers),
        sets => capture_sets(@containers),
    };
}

sub restore {
    my ($state) = @_;

    restore_sets( $state->{sets} );
    restore_rows( $state->{rows} );

    return;
}

# capture over the row sets resultset doubles keep. Each set is read again
# from its resultset at restore, so a resultset that replaced its container
# in the meantime gets the rows back in the one it now holds.
sub capture_resultsets {
    my (@resultsets) = @_;

    my ( @sets, @containers );
    for my $resultset ( grep { blessed $_ } @resultsets ) {
        for my $accessor (@ROW_SET_ACCESSOR) {
            next if !$resultset->can($accessor);
            my $held = $resultset->$accessor;
            next if !_is_container($held);
            push @containers, $held;
            push @sets,
              {
                accessor  => $accessor,
                held      => _copied($held),
                resultset => $resultset,
              };
        }
    }

    return { rows => capture_rows(@containers), sets => \@sets };
}

sub capture_sets {
    my (@containers) = @_;

    return [
        map  { { held => _copied($_), live => $_ } }
        grep { _is_container($_) } @containers
    ];
}

# Membership goes back into the live container, so a reference a test or a
# store already holds sees the rollback.
sub restore_sets {
    my ($sets) = @_;

    for my $row_set ( @{ $sets || [] } ) {
        my $held = $row_set->{held};
        my $live = _live_container($row_set);
        next if ref $live ne ref $held;
        if ( ref $held eq 'ARRAY' ) {
            @{$live} = @{$held};
            next;
        }
        %{$live} = %{$held};
    }

    return;
}

sub capture_rows {
    my (@containers) = @_;

    my ( %seen, @states );
    for my $container ( grep { _is_container($_) } @containers ) {
        for my $row ( _members($container) ) {
            next if !ref $row || $seen{ refaddr $row }++;
            my $columns = _columns_of($row);
            next if !$columns;
            push @states,
              { columns => { %{$columns} }, data => $columns, row => $row };
        }
    }

    return \@states;
}

# Columns go back into the hash the row held at capture, and a row whose
# update replaced its hash gets that one back.
sub restore_rows {
    my ($states) = @_;

    for my $state ( @{ $states || [] } ) {
        my ( $row, $data ) = @{$state}{qw(row data)};
        if ( _replaced( $row, $data ) ) {
            $row->data($data);
        }
        %{$data} = %{ $state->{columns} };
    }

    return;
}

sub _replaced {
    my ( $row, $data ) = @_;

    return 0 if !blessed $row || !$row->can('data');

    return refaddr( _columns_of($row) // {} ) != refaddr $data ? 1 : 0;
}

sub _live_container {
    my ($row_set) = @_;

    return $row_set->{live} if !$row_set->{resultset};

    my $accessor = $row_set->{accessor};

    return $row_set->{resultset}->$accessor;
}

sub _columns_of {
    my ($row) = @_;

    return $row              if ref $row eq 'HASH';
    return undef             if !blessed $row;
    return $row->column_data if $row->can('column_data');
    return undef             if !$row->can('data');

    my $data = $row->data;

    return ref $data eq 'HASH' ? $data : undef;
}

sub _members {
    my ($container) = @_;

    return ref $container eq 'ARRAY' ? @{$container} : values %{$container};
}

sub _is_container {
    my ($held) = @_;

    return ref $held eq 'ARRAY' || ref $held eq 'HASH' ? 1 : 0;
}

sub _copied {
    my ($held) = @_;

    return [ @{$held} ] if ref $held eq 'ARRAY';

    return { %{$held} };
}

1;

__END__

=head1 NAME

GPForum::Test::RowState - Snapshot and rollback of the fake resultsets' rows.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $state =
      GPForum::Test::RowState::capture_resultsets( values %{$resultsets} );
    ...    # the transaction body dies
    GPForum::Test::RowState::restore($state);

=head1 DESCRIPTION

What a transaction or a savepoint undoes, for the in-memory doubles: the
rows each row set holds and the columns each row holds. A row is a hash or a
row double whose columns are in C<column_data> or C<data>. Both are put back
in place, so a reference already handed out sees the rollback.

=head1 SUBROUTINES/METHODS

=head2 capture

Copies the membership of the given array or hash containers and the columns
of every row in them.

=head2 restore

Puts a capture back.

=head2 capture_resultsets

C<capture> over the C<created>, C<created_objects> and C<rows> containers of
the given resultset doubles, each read again from its resultset at restore.

=head2 capture_sets

Copies membership only.

=head2 restore_sets

Puts membership back.

=head2 capture_rows

Copies each row's columns only.

=head2 restore_rows

Puts each row's columns back.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Scalar::Util>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Copies one level of each row: a column holding a structure that the body
mutates in place is not restored.

=head1 AUTHOR

Giacomo Picchiarelli

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Giacomo Picchiarelli. BSD-3-Clause.

=cut
