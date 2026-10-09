# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Infrastructure::PreparedQuery;

use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Infrastructure::Id;
use Scalar::Util qw(blessed);

our $VERSION = '0.001';

# A statement DBIx::Class built once, run again with new values.
#
# DBIx::Class builds a resultset's SQL from scratch on every search. For the
# two statements a thread page runs, the building took seven times what
# PostgreSQL took to answer them. A reader whose statement has the same
# shape for every request -- the same joins, the same conditions; only the
# thread, the viewer, the cursor and the page size change -- has it built
# once, by DBIx::Class from its own resultset, and run again with the new
# values bound in the same places.
#
# What makes this safe is what makes any prepared statement safe. The SQL is
# DBIx::Class's own text and never sees a value: every value is a bind. A
# request fills the slots DBIx::Class bound for its columns (me.thread_id,
# me.author_user_id, a cursor's me.position and me.post_id) and the one slot
# with no column, the page size; every other slot keeps the constant the
# resultset bound, a visibility level or a moderation state. A statement
# whose slots are not those, or whose first run bound a value the request
# did not name, is not kept: the resultset runs as it is. Rows come back as
# the result class the resultset gives, with the columns the reader names.
#
# One shape is one entry, for the life of the process. A request with no
# shape, or a schema that is not a DBIx::Class schema (the tests' doubles),
# runs the resultset as it is, or the fallback the reader gives for it.

my %STATEMENT;

sub rows ( $self, %input ) {
    my $schema = $input{schema};
    return _resultset_rows(%input)
      if !defined $input{shape}
      || !blessed $schema
      || !$schema->isa('DBIx::Class::Schema');

    my $key       = ref($schema) . "\0" . $input{shape};
    my $statement = $STATEMENT{$key} //= _statement(%input);
    return _resultset_rows(%input) if !$statement;
    return _resultset_rows(%input) if !_fits( $statement, $input{values} );

    my $source = $schema->source( $input{source} );
    return [] if _refused( $source, $statement, $input{values} );

    my @values = _bound_values( $statement, $input{values} );
    my $rows   = _select( $schema, $statement->{sql}, \@values );
    my $class  = $source->result_class;
    my $as = $input{as} // [ $source->columns, @{ $input{extra_as} // [] } ];

    return [ map { $class->inflate_result( $source, _named( $as, $_ ) ) }
          @{$rows} ];
}

# The one row a lookup by a key answers, or undef.
sub row ( $self, %input ) {
    return $self->rows(%input)->[0];
}

sub _resultset_rows (%input) {
    return $input{fallback}->() if $input{fallback};

    return [ $input{resultset}->()->all ];
}

# The statement a shape runs, from the resultset built for this request: its
# SQL, and for each bind the column DBIx::Class bound it for and the value
# it bound. Undef when the binds are not the ones a request can fill.
sub _statement (%input) {
    my ( $sql, @bind ) = @{ ${ $input{resultset}->()->as_query } };
    my @slots =
      map { { column => $_->[0]{dbic_colname}, value => $_->[1] } } @bind;

    return undef if !_fillable( \@slots, $input{values} );

    return { sql => $sql, slots => \@slots };
}

# Every slot a request fills was bound with the request's own value, and
# exactly one slot, the page size, has no column.
sub _fillable ( $slots, $values ) {
    my $unnamed = 0;
    my %listed;
    for my $slot ( @{$slots} ) {
        if ( !defined $slot->{column} ) {
            $unnamed++;
            next;
        }
        next if !exists $values->{ $slot->{column} };

        # A list value fills one slot per element, in order: an IN list.
        my $given = $values->{ $slot->{column} };
        if ( ref $given eq 'ARRAY' ) {
            $given = $given->[ $listed{ $slot->{column} }++ ];
        }
        my $bound = $slot->{value} // q{};
        return 0 if $bound ne ( $given // q{} );
    }
    for my $column ( keys %listed ) {
        return 0 if $listed{$column} != @{ $values->{$column} };
    }

    # The page size is the one slot DBIx::Class binds without a column; a
    # lookup by a key has none.
    return $unnamed <= 1 ? 1 : 0;
}

# A request whose value for a column the statement does not bind -- the
# statement was built from a request that had none, and wrote IS NULL or
# nothing for it -- is not this statement's: it runs its resultset.
sub _fits ( $statement, $values ) {
    my %bound = map { ( $_->{column} // q{} ) => 1 } @{ $statement->{slots} };
    for my $column ( keys %{$values} ) {
        next     if $column eq 'limit';
        next     if !defined $values->{$column};
        return 0 if !$bound{$column};
    }

    return 1;
}

# A value bound for a uuid column of the source that PostgreSQL would not
# read as one: it comes from the URL (/t/anything), PostgreSQL would refuse
# the whole statement, and the page answered 500 for a row that is not
# there. The statement is not sent and there are no rows.
sub _refused ( $source, $statement, $values ) {
    for my $slot ( @{ $statement->{slots} } ) {
        my $column = $slot->{column} // next;
        next if !exists $values->{$column};
        next if !defined $values->{$column};

        ( my $name = $column ) =~ s/\A me [.]//msx;
        next if $name =~ /[.]/msx;
        next if !$source->has_column($name);
        next if ( $source->column_info($name)->{data_type} // q{} ) ne 'uuid';

        my $given = $values->{$column};
        for my $value ( ref $given eq 'ARRAY' ? @{$given} : $given ) {
            return 1
              if !GPForum::Infrastructure::Id->is_uuid_spelling($value);
        }
    }

    return 0;
}

sub _bound_values ( $statement, $values ) {
    my %listed;
    my @bound;
    for my $slot ( @{ $statement->{slots} } ) {
        my $column = $slot->{column};
        if ( !defined $column ) {
            push @bound, $values->{limit};
        }
        elsif ( !exists $values->{$column} ) {
            push @bound, $slot->{value};
        }
        elsif ( ref $values->{$column} eq 'ARRAY' ) {
            push @bound, $values->{$column}[ $listed{$column}++ ];
        }
        else {
            push @bound, $values->{$column};
        }
    }

    return @bound;
}

# Run through the schema's handle, prepared once per handle, and reported to
# the storage's statistics as every DBIx::Class statement is (what
# Infrastructure::CountedQuery does for one row).
sub _select ( $schema, $sql, $values ) {
    my $storage = $schema->storage;
    my $stats   = $storage->debug ? $storage->debugobj : undef;
    if ($stats) {
        $stats->query_start( $sql, @{$values} );
    }
    my $rows = $storage->dbh_do(
        sub ( $, $dbh ) {
            my $handle = $dbh->prepare_cached($sql);
            $handle->execute( @{$values} );
            return $handle->fetchall_arrayref;
        }
    );
    if ($stats) {
        $stats->query_end( $sql, @{$values} );
    }

    return $rows;
}

sub _named ( $as, $row ) {
    my %named;
    @named{ @{$as} } = @{$row};

    return \%named;
}

1;

__END__

=head1 NAME

GPForum::Infrastructure::PreparedQuery - A resultset's statement, built once and run with new values.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $rows = GPForum::Infrastructure::PreparedQuery->new->rows(
        schema    => $schema,
        shape     => 'posts:member:first',
        source    => 'Post',
        as        => [qw(post_id thread_id body author_username)],
        resultset => sub { return $reader->thread_posts_resultset($request) },
        values    => {
            'me.thread_id'       => $thread_id,
            'me.author_user_id'  => $viewer_user_id,
            limit                => $fetch_rows,
        },
    );

=head1 DESCRIPTION

Runs the statement a resultset would run, with its SQL built once per shape
and kept for the life of the process, and every value bound. The comment at
the top of the module says what a shape is, which slots a request fills and
when a statement is not kept.

=head1 SUBROUTINES/METHODS

=head2 row

Takes what L</rows> takes and returns the first row, or undef when there
is none: a lookup by a key.

=head2 rows

Takes C<schema>, C<shape>, a name that identifies the statement's shape;
C<source>, the result source whose class the rows get; C<as>, the names of
the selected columns in the order the resultset selects them (the source's
own columns, in its order, when not given, followed by C<extra_as>, the
names of the resultset's C<+as> columns, when given); C<resultset>,
a code reference that builds the resultset for this request; and C<values>,
the request's values by the column DBIx::Class binds them for (an array
reference for a column bound once per element, an IN list, whose length
the shape must name), plus C<limit> when the statement has a page size. Optionally C<fallback>, a code reference that returns the rows
when the statement is not prepared (a double that answers C<find> but not
a search, say). Returns an array reference of result rows.

A request whose value for a column the kept statement does not bind runs
its resultset instead: the statement was built from a request without that
value. A value bound for a uuid column of the source that PostgreSQL would
not read as a uuid (L<GPForum::Infrastructure::Id/is_uuid_spelling>) sends
no statement and answers no rows, as a row that is not there would.

=head1 DIAGNOSTICS

None. A statement that cannot be filled from C<values> is not kept, and the
resultset runs as it is.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>, L<Scalar::Util>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The names in C<as> must be the resultset's own selection order: the
resultset's columns, then its C<+as> names.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
