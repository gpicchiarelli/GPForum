# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ReadStateResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::ReadStateRow;

our $VERSION = '0.001';

has created     => sub { return []; };
has find_misses => 0;
has rows        => sub { return {}; };
has schema      => undef;
has unique_name => sub { return 'thread_read_state_pkey'; };

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_usable;
    $self->_assert_unique($row);
    my $object = GPForum::Test::ReadStateRow->new( data => { %{$row} } );
    $self->rows->{ _key($row) } = $object;
    push @{ $self->created }, { %{$row} };

    return $object;
}

sub update_or_create {
    my ( $self, $row ) = @_;

    $self->_assert_usable;
    my $existing = $self->rows->{ _key($row) };
    if ($existing) {
        return $existing->update($row);
    }

    return $self->create($row);
}

sub find {
    my ( $self, $query ) = @_;

    $self->_assert_usable;
    if ( $self->find_misses ) {
        $self->find_misses( $self->find_misses - 1 );
        return;
    }

    return $self->rows->{ _key($query) };
}

# A unique violation is what puts a real transaction into the aborted state.
# Marking it here is what makes the doubles able to fail a recovery path that
# would be unreachable against PostgreSQL.
sub _assert_unique {
    my ( $self, $row ) = @_;

    my $ok = eval {
        $self->_run_unique($row);
        1;
    };
    if ( !$ok ) {
        my $failure = $@;
        $self->_mark_aborted;
        die $failure;    ## no critic (ErrorHandling::RequireCarping)
    }

    return;
}

sub _run_unique {
    my ( $self, $row ) = @_;

    my $key = _key($row);
    if ( $key && $self->rows->{$key} ) {
        GPForum::Infrastructure::UniqueConflict->throw( $self->unique_name );
    }

    return;
}

sub _assert_usable {
    my ($self) = @_;

    my $schema = $self->schema;
    if ( $schema && $schema->can('assert_transaction_usable') ) {
        $schema->assert_transaction_usable;
    }

    return;
}

sub _mark_aborted {
    my ($self) = @_;

    my $schema = $self->schema;
    if ( $schema && $schema->can('mark_transaction_aborted') ) {
        $schema->mark_transaction_aborted;
    }

    return;
}

sub _key {
    my ($row) = @_;

    return join q{:}, @{$row}{qw(user_id thread_id)};
}

1;
