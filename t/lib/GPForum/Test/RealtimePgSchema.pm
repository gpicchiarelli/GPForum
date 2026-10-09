# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimePgSchema;

use v5.40;

use GPForum::Test::RealtimePgStorage;

our $VERSION = '0.001';

sub new {
    my ( $class, %input ) = @_;

    return bless { dbh => $input{dbh} }, $class;
}

sub dbh {
    my ($self) = @_;

    return $self->{dbh};
}

sub storage {
    my ($self) = @_;

    return GPForum::Test::RealtimePgStorage->new( dbh => $self->dbh );
}

1;
