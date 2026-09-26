# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OutboxCreateResultSet;

use strict;
use warnings;

use Carp    qw(croak);
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;

our $VERSION = '0.001';

has created => sub { return []; };

# A store failure that is not a unique violation, so a caller cannot mistake
# it for a replay it is allowed to absorb.
has fail_error  => undef;
has find_misses => 0;
has rows        => sub { return {}; };
has schema      => undef;

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_usable;
    if ( defined $self->fail_error ) {
        croak $self->fail_error;
    }
    $self->_assert_unique_constraints($row);
    $self->rows->{ _source_key($row) } = $row;
    push @{ $self->created }, $row;

    return $row;
}

sub find {
    my ( $self, $query ) = @_;

    $self->_assert_usable;
    if ( $self->find_misses ) {
        $self->find_misses( $self->find_misses - 1 );
        return;
    }

    return $self->rows->{ _source_key($query) };
}

# A unique violation is what puts a real transaction into the aborted state.
# Marking it here is what lets the double fail a recovery path that would be
# unreachable against PostgreSQL.
sub _assert_unique_constraints {
    my ( $self, $row ) = @_;

    my $ok = eval {
        $self->_run_unique_constraints($row);
        1;
    };
    if ( !$ok ) {
        my $failure = $EVAL_ERROR;
        $self->_mark_aborted;

        ## no critic (ErrorHandling::RequireCarping)
        # Rethrowing the original exception object: croak would stringify it
        # and the caller classifies unique violations by object.
        die $failure;
        ## use critic
    }

    return;
}

sub _run_unique_constraints {
    my ( $self, $row ) = @_;

    $self->_assert_letter_id_unique($row);
    $self->_assert_source_unique($row);

    return;
}

# PostgreSQL refuses every statement after an error inside a transaction until
# something rolls back. The schema is optional so this resultset still works
# with a double that has not adopted the transactional base.
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

sub _assert_letter_id_unique {
    my ( $self, $row ) = @_;

    my $letter_id = $row->{dead_letter_id};
    if ( !_has_text($letter_id) ) {
        return;
    }
    if ( _letter_id_taken( $self, $letter_id ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('dead_letters_pkey');
    }

    return;
}

sub _letter_id_taken {
    my ( $self, $letter_id ) = @_;

    for my $existing ( @{ $self->created } ) {
        if ( _same_text( $existing->{dead_letter_id}, $letter_id ) ) {
            return 1;
        }
    }

    return 0;
}

sub _assert_source_unique {
    my ( $self, $row ) = @_;

    my $key = _source_key($row);
    if ( $key && $self->rows->{$key} ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'idx_dead_letters_source_unique');
    }

    return;
}

sub _source_key {
    my ($row) = @_;

    my $source_id    = $row->{source_id};
    my $source_table = $row->{source_table};
    if ( !defined $source_id || !defined $source_table ) {
        return q{};
    }

    return join q{:}, $source_table, $source_id;
}

sub _has_text {
    my ($value) = @_;

    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

sub _same_text {
    my ( $expected, $actual ) = @_;

    return ( $expected || q{} ) eq ( $actual || q{} ) ? 1 : 0;
}

1;
