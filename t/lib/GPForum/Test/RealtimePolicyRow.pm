# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimePolicyRow;

use v5.40;

our $VERSION = '0.001';

sub new {
    my ( $class, %input ) = @_;

    return bless { data => $input{data} || {} }, $class;
}

sub data {
    my ($self) = @_;

    return $self->{data};
}

sub get_column {
    my ( $self, $column ) = @_;

    return $self->data->{$column};
}

1;
