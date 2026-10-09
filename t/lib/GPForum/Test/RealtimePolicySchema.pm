# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimePolicySchema;

use v5.40;

use GPForum::Test::RealtimePolicyResultSet;

our $VERSION = '0.001';

sub new {
    my ( $class, %input ) = @_;

    return bless { users => $input{users} || {} }, $class;
}

sub users {
    my ($self) = @_;

    return $self->{users};
}

sub resultset {
    my ( $self, $name ) = @_;

    return GPForum::Test::RealtimePolicyResultSet->new(
        name   => $name,
        schema => $self,
    );
}

1;
