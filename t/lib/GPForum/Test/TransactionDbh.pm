# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::TransactionDbh;

use Carp qw(croak);
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A database handle that records each call in order, and fails the ones it
# was told to: a SELECT, or the ROLLBACK itself.
has calls            => sub { return []; };
has fail_on_select   => 0;
has fail_on_rollback => 0;

sub begin_work ($self) {
    push @{ $self->calls }, 'begin_work';

    return 1;
}

sub do ( $self, $sql, @ ) {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    push @{ $self->calls }, $sql;

    return 1;
}

sub selectrow_array ( $self, $sql, @ ) {
    push @{ $self->calls }, 'select';
    croak 'explain failed' if $self->fail_on_select;

    return '[{"Plan":{}}]';
}

sub commit ($self) {
    push @{ $self->calls }, 'commit';

    return 1;
}

sub rollback ($self) {
    push @{ $self->calls }, 'rollback';
    croak 'rollback failed' if $self->fail_on_rollback;

    return 1;
}

1;
