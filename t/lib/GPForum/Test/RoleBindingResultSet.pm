# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RoleBindingResultSet;

use Const::Fast;
use Mojo::Base -base;
use v5.40;

use GPForum::Test::RoleBindingRow;
use GPForum::Test::RoleBindingSearch;

our $VERSION = '0.001';

const my %ID_COLUMN => (
    AuditLog    => 'audit_id',
    RoleBinding => 'binding_id',
);

# One named resultset of a RoleBindingSchema: rows it creates are kept in the
# schema, so a later resultset of the same name finds them.
has 'name';
has 'schema';

sub create {
    my ( $self, $row ) = @_;

    push @{ $self->schema->created_for( $self->name ) }, $row;
    my $stored = GPForum::Test::RoleBindingRow->new( columns => { %{$row} } );
    push @{ $self->schema->rows_for( $self->name ) }, $stored;

    return $stored;
}

sub find {
    my ( $self, $id, $attrs ) = @_;

    push @{ $self->schema->find_attrs }, $attrs;
    my $column = $ID_COLUMN{ $self->name };
    return undef if !$column;

    return $self->search( { $column => $id } )->single;
}

# DBIx::Class's context-proof form of search, which lib/ calls.
sub search_rs {
    my ( $self, @arguments ) = @_;

    return $self->search(@arguments);
}

sub search {
    my ( $self, $where ) = @_;

    my @matched = grep { _matches( $_, $where ) }
      @{ $self->schema->rows_for( $self->name ) };

    return GPForum::Test::RoleBindingSearch->new( matched => \@matched );
}

sub _matches {
    my ( $row, $where ) = @_;

    for my $column ( keys %{$where} ) {
        my $actual = $row->get_column($column);
        my $wanted = $where->{$column};
        if ( !defined $wanted ) {
            return 0 if defined $actual;
            next;
        }
        return 0 if !defined $actual || $actual ne $wanted;
    }

    return 1;
}

1;
