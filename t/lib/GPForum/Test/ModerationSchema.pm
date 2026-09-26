# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ModerationSchema;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base 'GPForum::Test::TransactionalSchema';

our $VERSION = '0.001';

# Row sets a moderation resultset double keeps. They live on the resultsets
# rather than on the schema, which is why this double has no storage accessors
# of its own and snapshots the resultsets instead.
const my @ROW_SET_ACCESSOR => qw(created created_objects rows);

has resultsets => sub { return {}; };

sub new {
    my ( $class, @arguments ) = @_;

    my $self = $class->SUPER::new(@arguments);
    $self->_adopt_resultsets;
    $self->_adopt_storage;

    return $self;
}

sub resultset {
    my ( $self, $name ) = @_;

    return $self->resultsets->{$name} if exists $self->resultsets->{$name};

    croak 'unexpected resultset';
}

sub storage_accessors {
    return ();
}

sub snapshot {
    my ($self) = @_;

    my $snapshot = $self->SUPER::snapshot;
    my @held;
    for my $resultset ( values %{ $self->resultsets } ) {
        push @held, _held_row_sets($resultset);
    }
    $snapshot->{row_sets} = \@held;

    return $snapshot;
}

sub restore {
    my ( $self, $snapshot ) = @_;

    $self->SUPER::restore($snapshot);
    for my $entry ( @{ $snapshot->{row_sets} || [] } ) {
        _restore_row_set($entry);
    }

    return;
}

# A resultset double answers queries, so it needs a way back to the schema to
# see whether the transaction is aborted.
sub _adopt_resultsets {
    my ($self) = @_;

    for my $resultset ( values %{ $self->resultsets } ) {
        next if !ref $resultset;
        next if !$resultset->can('schema');
        next if $resultset->schema;
        $resultset->schema($self);
    }

    return;
}

# A test that injects its own storage double, to watch the lock statements a
# store issues, still needs the savepoint surface bound to this schema, or
# conflict recovery degrades to a plain eval and stops testing the real thing.
sub _adopt_storage {
    my ($self) = @_;

    my $storage = $self->storage;
    if ( $storage && $storage->can('schema') && !$storage->schema ) {
        $storage->schema($self);
    }

    return;
}

sub _held_row_sets {
    my ($resultset) = @_;

    my @entries;
    for my $accessor (@ROW_SET_ACCESSOR) {
        next if !_holds_row_set( $resultset, $accessor );
        push @entries,
          {
            accessor  => $accessor,
            held      => _copied( $resultset->$accessor ),
            resultset => $resultset,
          };
    }

    return @entries;
}

sub _holds_row_set {
    my ( $resultset, $accessor ) = @_;

    return 0 if !ref $resultset;
    return 0 if !$resultset->can($accessor);

    return ref $resultset->$accessor ? 1 : 0;
}

sub _copied {
    my ($held) = @_;

    return [ @{$held} ] if ref $held eq 'ARRAY';

    return { %{$held} };
}

sub _restore_row_set {
    my ($entry) = @_;

    my $accessor = $entry->{accessor};
    my $live     = $entry->{resultset}->$accessor;
    my $held     = $entry->{held};

    if ( ref $held eq 'ARRAY' ) {
        @{$live} = @{$held};
        return;
    }

    %{$live} = %{$held};

    return;
}

1;
