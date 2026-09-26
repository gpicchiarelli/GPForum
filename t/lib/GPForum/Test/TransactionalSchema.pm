# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::TransactionalSchema;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;
use Try::Tiny;

use GPForum::Test::Storage;

our $VERSION = '0.001';

has created             => sub { return {}; };
has transactions        => 0;
has transaction_aborted => 0;
has transaction_depth   => 0;
has storage => sub { return GPForum::Test::Storage->new( schema => shift ); };

# Subclasses list the accessors holding their rows, so snapshot and restore —
# and therefore savepoint rollback — work without each double reimplementing
# them.
sub storage_accessors {
    return ();
}

sub txn_do {
    my ( $self, $code ) = @_;

    my $snapshot = $self->snapshot;
    $self->transactions( $self->transactions + 1 );
    $self->transaction_depth( $self->transaction_depth + 1 );

    my $result;
    my $failure;
    try {
        $result = $code->();
    }
    catch {
        $failure = $_;
    };
    $self->_leave_transaction;
    if ($failure) {
        $self->restore($snapshot);
        croak $failure;
    }

    return $result;
}

sub transaction_count {
    my ($self) = @_;

    return $self->transactions;
}

# PostgreSQL refuses every statement after an error inside a transaction until
# the caller rolls back, to a savepoint or entirely. A double that keeps
# answering queries lets a recovery path that cannot run in production look
# correct in the unit suite, which is how a broken conflict recovery survived in
# twenty-eight stores. See docs/QUALITY_PROGRAM.md.
sub assert_transaction_usable {
    my ($self) = @_;

    if ( !$self->transaction_aborted ) {
        return;
    }

    croak 'DBD::Pg::st execute failed: ERROR:  current transaction is '
      . 'aborted, commands ignored until end of transaction block (25P02)';
}

sub mark_transaction_aborted {
    my ($self) = @_;

    if ( $self->transaction_depth ) {
        $self->transaction_aborted(1);
    }

    return;
}

sub clear_transaction_aborted {
    my ($self) = @_;

    $self->transaction_aborted(0);

    return;
}

sub snapshot {
    my ($self) = @_;

    my %snapshot =
      map { $_ => [ @{ $self->$_ } ] } $self->storage_accessors;
    $snapshot{created} =
      { map { $_ => [ @{ $self->created->{$_} } ] } keys %{ $self->created } };

    return \%snapshot;
}

sub restore {
    my ( $self, $snapshot ) = @_;

    for my $accessor ( $self->storage_accessors ) {
        @{ $self->$accessor } = @{ $snapshot->{$accessor} };
    }
    $self->_restore_created( $snapshot->{created} );

    return;
}

sub created_for {
    my ( $self, $name ) = @_;

    $self->created->{$name} ||= [];

    return $self->created->{$name};
}

sub _restore_created {
    my ( $self, $held ) = @_;

    for my $name ( keys %{ $self->created } ) {
        @{ $self->created->{$name} } = @{ $held->{$name} || [] };
    }

    return;
}

sub _leave_transaction {
    my ($self) = @_;

    $self->transaction_depth( $self->transaction_depth - 1 );
    if ( $self->transaction_depth > 0 ) {
        return;
    }

    $self->transaction_aborted(0);

    # A subclass may substitute its own storage double; only one that keeps a
    # savepoint stack needs clearing between transactions.
    my $storage = $self->storage;
    if ( $storage && $storage->can('reset_savepoints') ) {
        $storage->reset_savepoints;
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Test::TransactionalSchema - Base for schema doubles that model
PostgreSQL transaction semantics.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    package GPForum::Test::ThingSchema;
    use Mojo::Base 'GPForum::Test::TransactionalSchema';

    has things => sub { return []; };

    sub storage_accessors { return qw(things) }

=head1 DESCRIPTION

Gives a schema double the transaction behaviour that matters for correctness:
depth tracking, snapshot and restore on rollback, a savepoint-capable
L<GPForum::Test::Storage>, and PostgreSQL's rule that a failed statement poisons
the transaction until something rolls back.

A double without that rule reports success for recovery code that could never
run against a real database. Twenty-eight stores carried an unreachable
conflict-recovery branch behind exactly that gap.

Subclasses declare their row accessors through C<storage_accessors> and get
snapshot, restore and savepoint rollback for free.

=head1 SUBROUTINES/METHODS

=head2 storage_accessors

The accessors holding rows. Empty by default; subclasses override it.

=head2 txn_do

Runs the code with depth tracking, restoring the snapshot and rethrowing on
failure.

=head2 transaction_count

How many transactions have been opened.

=head2 assert_transaction_usable

Croaks with PostgreSQL's 25P02 wording when the transaction is aborted.

=head2 mark_transaction_aborted

Marks the transaction aborted, but only inside one.

=head2 clear_transaction_aborted

Clears the aborted state, as a savepoint rollback does.

=head2 snapshot

Copies the declared row accessors and the created-row log.

=head2 restore

Puts a snapshot back.

=head2 created_for

The created-row log for one result source.

=head1 DIAGNOSTICS

C<assert_transaction_usable> croaks on an aborted transaction; C<txn_do>
rethrows whatever the block raised.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>, L<Carp>, L<Try::Tiny>, L<GPForum::Test::Storage>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Snapshots copy one level, which is what the doubles' row arrays need.

=head1 AUTHOR

Giacomo Picchiarelli

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Giacomo Picchiarelli. BSD-3-Clause.

=cut
