# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::Row;

use Carp qw(croak);
use Mojo::Base -base;
use v5.40;

use Mojo::Loader qw(load_class);

our $VERSION = '0.001';

has data       => sub { return {}; };
has in_storage => 1;

# optional: without it the double cannot know the source's columns, so it
# answers every loaded column and refuses none.
has result_class => undef;
has updates      => sub { return []; };

# DBIx::Class answers a loaded column, including one a query selected under
# +as, and refuses a name that is neither loaded nor a column of the source.
# Without a result class the double cannot tell the two apart and answers
# undef, which is what a column the query did not select reads as.
sub get_column {
    my ( $self, $column ) = @_;

    my $data = $self->column_data;
    return $self->_deflated( $column, $data->{$column} )
      if exists $data->{$column};

    $self->_assert_column($column);

    return undef;
}

sub get_columns {
    my ($self) = @_;

    my $data = $self->column_data;

    return map { $_ => $self->_deflated( $_, $data->{$_} ) } keys %{$data};
}

sub has_column_loaded {
    my ( $self, $column ) = @_;

    return exists $self->column_data->{$column} ? 1 : 0;
}

# DBIx::Class refuses a name that is not a column, in column_info's words, and
# a column its source does not inflate. A test stores the structure an
# inflated column holds, so it comes back as stored; a JSON text is decoded as
# the source's inflator would.
sub get_inflated_column {
    my ( $self, $column ) = @_;

    my $class = $self->_loaded_result_class;
    croak "No such column $column" if $class && !$class->has_column($column);

    my $inflate = $self->_inflate_info($column);
    if ( $self->result_class && !$inflate ) {
        croak "$column is not an inflated column";
    }

    my $value = $self->column_data->{$column};
    return $value if !$inflate || !defined $value || ref $value;

    return $inflate->{inflate}->( $value, $self );
}

sub set_column {
    my ( $self, $column, $value ) = @_;

    if ( !exists $self->column_data->{$column} ) {
        $self->_assert_column($column);
    }
    $self->write_columns( { $column => $value } );

    return $value;
}

# The columns are checked before any is written, as store_column refuses an
# unknown one before DBIx::Class issues the UPDATE.
sub update {
    my ( $self, $changes ) = @_;

    $changes ||= {};
    my $data = $self->column_data;
    for my $column ( keys %{$changes} ) {
        next if exists $data->{$column};
        $self->_assert_column($column);
    }
    return $self if !%{$changes};

    croak 'Not in database' if !$self->in_storage;
    push @{ $self->updates }, $changes;
    $self->write_columns($changes);

    return $self;
}

# delete, aliased as the other doubles alias it, since a sub of that name
# reads as the builtin.
sub delete_row {
    my ($self) = @_;

    croak 'Not in database' if !$self->in_storage;
    $self->remove_from_storage;
    $self->in_storage(0);

    return $self;
}

BEGIN {
    *delete = \&delete_row;
}

sub discard_changes {
    my ($self) = @_;

    return $self;
}

sub result_source {
    my ($self) = @_;

    my $class = $self->_loaded_result_class;
    return undef if !$class;

    return $class->result_source_instance;
}

# Column accessors exist only for the source's own columns, as DBIx::Class
# generates them from the result class; a column a query added under +as is
# reachable through get_column alone. A row given a result class is blessed
# into a subclass holding that source's accessors, so can() answers them as it
# does for a real row.
sub new {
    my ( $class, @arguments ) = @_;

    my $self         = $class->SUPER::new(@arguments);
    my $result_class = $self->_loaded_result_class;
    return $self if !$result_class;

    return bless $self, _accessor_class( ref $self, $result_class );
}

sub _accessor_class {
    my ( $class, $result_class ) = @_;

    state %built;
    my $name = $class . '::Columns::' . ( $result_class =~ s/::/_/gmsxr );
    return $name if $built{$name}++;

    ## no critic (TestingAndDebugging::ProhibitNoStrict)
    no strict 'refs';
    @{"${name}::ISA"} = ($class);
    for my $column ( $result_class->columns ) {
        next if $class->can($column);
        *{"${name}::$column"} = sub {
            my ( $row, @value ) = @_;

            return $row->set_column( $column, @value ) if @value;

            return $row->get_column($column);
        };
    }
    ## use critic

    return $name;
}

# The hash a subclass keeps its columns in; most keep them in data.
sub column_data {
    my ($self) = @_;

    return $self->data;
}

# Writes in place, so a resultset that holds the same hash sees the change as
# a table would. A subclass whose resultset keeps its own copy overrides this.
sub write_columns {
    my ( $self, $changes ) = @_;

    my $data = $self->column_data;
    @{$data}{ keys %{$changes} } = values %{$changes};

    return;
}

# What delete removes from the double's storage; a subclass that knows its
# resultset overrides it.
sub remove_from_storage {
    return;
}

sub _assert_column {
    my ( $self, $column ) = @_;

    my $class = $self->_loaded_result_class;
    return if !$class;
    return if $class->has_column($column);

    croak "No such column '$column' on $class";
}

sub _inflate_info {
    my ( $self, $column ) = @_;

    my $class = $self->_loaded_result_class;
    return undef if !$class || !$class->has_column($column);

    return $class->column_info($column)->{_inflate_info};
}

# DBIx::Class keeps an inflated value apart and deflates it when the raw
# column is read, so get_column on a JSON column is JSON text.
sub _deflated {
    my ( $self, $column, $value ) = @_;

    return $value if !ref $value || !$self->result_class;

    my $inflate = $self->_inflate_info($column);
    return $value if !$inflate || !$inflate->{deflate};

    return $inflate->{deflate}->( $value, $self );
}

sub _loaded_result_class {
    my ($self) = @_;

    my $class = $self->result_class;
    return undef if !$class;

    my $error = load_class($class);
    croak "cannot load $class: $error" if ref $error;
    croak "cannot load $class"         if $error;

    return $class;
}

1;

__END__

=head1 NAME

GPForum::Test::Row - Row double with the DBIx::Class row surface.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $row = GPForum::Test::Row->new(
        data         => { report_id => 'r-1', status => 'open' },
        result_class => 'GPForum::Schema::Result::Report',
    );
    $row->get_column('status');        # 'open'
    $row->status;                      # 'open', a column accessor
    $row->update( { status => 'resolved' } );
    $row->get_column('no_such');       # croaks, as DBIx::Class does

=head1 DESCRIPTION

The row a fake resultset returns. It answers the DBIx::Class row methods the
application calls -- C<get_column>, C<get_columns>, C<has_column_loaded>,
C<get_inflated_column>, C<set_column>, C<update>, C<delete>, C<in_storage>,
C<discard_changes>, C<result_source> and the column accessors -- so code that
reads a row does not need to ask whether it holds a real one.

Given a C<result_class> (a C<GPForum::Schema::Result> class), it holds the
source's rules: a name that is neither loaded nor a column is refused,
accessors exist for the columns, C<get_inflated_column> refuses a column the
source does not inflate, and C<get_column> on a JSON column returns the JSON
text DBIx::Class would. Without one it answers every loaded column and
refuses nothing, because it cannot know the source.

=head1 SUBROUTINES/METHODS

=head2 get_column

The loaded value, undef for a column of the source that was not loaded, and
an exception for a name that is neither.

=head2 get_columns

Every loaded column, raw.

=head2 has_column_loaded

True when the column is loaded.

=head2 get_inflated_column

The inflated value of an inflated column.

=head2 set_column

Sets one column, refusing a name that is not a column.

=head2 update

Applies the changes, records them in C<updates>, and returns the row. Croaks
C<Not in database> for a deleted row, as DBIx::Class does.

=head2 delete

Calls C<remove_from_storage>, marks the row as no longer in storage and
returns it. Croaks C<Not in database> when it already was.

=head2 discard_changes

Returns the row; the double holds no stale copy.

=head2 result_source

The result class's source, or undef without a result class.

=head2 new

Builds the row; given a result class, blesses it into a subclass with that
source's column accessors.

=head2 column_data

The hash holding the columns. Subclasses that keep them elsewhere override it.

=head2 write_columns

Writes changed columns into C<column_data>, in place.

=head2 remove_from_storage

What C<delete> removes from the fake storage; nothing by default.

=head1 DIAGNOSTICS

C<No such column 'NAME' on CLASS>, C<No such column NAME> (from
C<get_inflated_column>), C<NAME is not an inflated column> and C<Not in
database>, worded as DBIx::Class words them.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>, L<Mojo::Loader>, L<Carp>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

No dirty-column tracking: C<set_column> writes at once. Relationship
accessors are not modelled.

=head1 AUTHOR

Giacomo Picchiarelli

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Giacomo Picchiarelli. BSD-3-Clause.

=cut
