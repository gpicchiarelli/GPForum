# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ViewModelRow;

use v5.40;

our $VERSION = '0.001';

# A row as the view-model presenters read it: columns by name, and the
# related rows (current_body) a prefetch would have joined.

sub new {
    my ( $class, $columns, %related ) = @_;

    return bless { columns => $columns || {}, related => \%related }, $class;
}

sub get_column {
    my ( $self, $name ) = @_;

    return $self->{columns}{$name};
}

sub current_body {
    my ($self) = @_;

    return $self->{related}{current_body};
}

1;
