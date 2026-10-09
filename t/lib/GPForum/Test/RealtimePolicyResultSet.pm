# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimePolicyResultSet;

use v5.40;

use GPForum::Test::RealtimePolicyRow;

our $VERSION = '0.001';

sub new {
    my ( $class, %input ) = @_;

    return bless { name => $input{name}, schema => $input{schema} }, $class;
}

sub name {
    my ($self) = @_;

    return $self->{name};
}

sub schema {
    my ($self) = @_;

    return $self->{schema};
}

sub find {
    my ( $self, $id ) = @_;

    return if $self->name ne 'User';

    my $row = $self->schema->users->{$id};
    return if !$row;

    return GPForum::Test::RealtimePolicyRow->new( data => $row );
}

1;
