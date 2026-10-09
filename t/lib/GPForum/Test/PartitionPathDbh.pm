# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PartitionPathDbh;

use Carp qw(croak);
use Mojo::Base 'GPForum::Test::PartitionDbh';
use v5.40;

our $VERSION = '0.001';

# PartitionDbh with the failures t/387 needs besides its own: state is what
# DBI reports as the last SQLSTATE, registry_error fails every
# partition_registry upsert, and wait_error fails pg_advisory_lock outright.
has registry_error => undef;
has state          => undef;
has wait_error     => undef;

sub execute_statement {
    my ( $self, $sql, $attributes, @bind ) = @_;
    if (   $self->registry_error
        && $sql =~ /\A INSERT [ ] INTO [ ] partition_registry/msx )
    {
        push @{ $self->statements }, { bind => \@bind, sql => $sql };
        croak $self->registry_error;
    }

    return $self->SUPER::execute_statement( $sql, $attributes, @bind );
}

sub selectrow_array {
    my ( $self, $sql, $attributes, @bind ) = @_;
    if ( $self->wait_error && $sql =~ /pg_advisory_lock[(]/msx ) {
        croak $self->wait_error;
    }

    return $self->SUPER::selectrow_array( $sql, $attributes, @bind );
}

1;

