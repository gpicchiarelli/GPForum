# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimePgDbh;

use v5.40;

our $VERSION = '0.001';

sub new {
    my ( $class, %input ) = @_;

    return bless {
        AutoCommit => 1,
        notifies   => $input{notifies}   || [],
        pg_pid     => $input{pg_pid}     || 1,
        statements => $input{statements} || [],
    }, $class;
}

sub quote_identifier {
    my ( undef, $identifier ) = @_;

    return q{"} . $identifier . q{"};
}

sub notifies {
    my ($self) = @_;

    return $self->{notifies};
}

sub statements {
    my ($self) = @_;

    return $self->{statements};
}

sub do {    ## no critic (Subroutines::ProhibitBuiltinHomonyms) -- DBI's method
    my ( $self, @arguments ) = @_;

    push @{ $self->statements }, \@arguments;

    return 1;
}

sub pg_notifies {
    my ($self) = @_;

    return shift @{ $self->notifies };
}

1;
