# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::Storage;

use Mojo::Base 'GPForum::Test::BareStorage';
use v5.40;

use GPForum::Test::Dbh;

our $VERSION = '0.001';

has schema    => undef;
has snapshots => sub { return []; };

# GPForum::Infrastructure::UniqueConflict only takes a savepoint when the
# handle is inside a transaction, which it decides from AutoCommit. Model that
# rather than always claiming to be transactional, so a double used outside
# txn_do behaves like autocommit DBI does.
sub dbh {
    my ($self) = @_;

    return GPForum::Test::Dbh->new(
        AutoCommit => $self->transaction_depth ? 0 : 1 );
}

# A storage double is sometimes built standalone, with no schema behind it.
sub transaction_depth {
    my ($self) = @_;

    my $schema = $self->schema;
    if ( !$schema || !$schema->can('transaction_depth') ) {
        return 0;
    }

    return $schema->transaction_depth;
}

# Not DBIx::Class's: its storage has no txn_depth, so on PostgreSQL
# EventRecorder::_needs_transaction, which asks for it, never opens the
# transaction its advisory lock needs. Kept only while that and
# PostStoreLockStorage still ask; drop it when they ask for transaction_depth.
sub txn_depth {
    my ($self) = @_;

    return $self->transaction_depth;
}

# DBIx::Class mints savepoint_N when the caller passes no name, and callers
# rely on reading the generated name back off the stack.
sub svp_begin {
    my ( $self, @name ) = @_;

    my $answer = $self->SUPER::svp_begin(@name);
    push @{ $self->snapshots }, $self->schema->snapshot;

    return $answer;
}

# PostgreSQL keeps the named savepoint established after a rollback to it, and
# DBIx::Class keeps it on the stack for the same reason: "a rollback doesn't
# remove the named savepoint, only everything after it". Discarding it here
# would let a caller that forgets its release look balanced.
sub svp_rollback {
    my ( $self, $name ) = @_;

    my $index =
      $self->savepoint_index( $self->savepoint_named( $name, q{rollback} ) );
    $self->schema->restore( $self->snapshots->[$index] );
    splice @{ $self->savepoints }, $index + 1;
    splice @{ $self->snapshots },  $index + 1;

    # Rolling back to a savepoint is exactly what makes an aborted transaction
    # usable again. This is the behaviour the whole double exists to model.
    $self->schema->clear_transaction_aborted;

    return 1;
}

sub svp_release {
    my ( $self, $name ) = @_;

    my $index =
      $self->savepoint_index( $self->savepoint_named( $name, q{release} ) );
    splice @{ $self->savepoints }, $index;
    splice @{ $self->snapshots },  $index;

    return 1;
}

sub reset_savepoints {
    my ($self) = @_;

    @{ $self->savepoints } = ();
    @{ $self->snapshots }  = ();

    return;
}

1;

__END__

=head1 NAME

GPForum::Test::Storage - Savepoint-aware storage double.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $storage = $schema->storage;
    $storage->svp_begin;
    my $name = $storage->savepoints->[-1];
    $storage->svp_rollback($name);
    $storage->svp_release($name);

=head1 DESCRIPTION

Gives an in-memory schema double the small part of the
L<DBIx::Class::Storage::DBI> contract that
L<GPForum::Infrastructure::UniqueConflict> depends on: C<dbh>, C<transaction_depth>,
and the C<svp_*> trio over a named savepoint stack.

Without it a double reports no storage at all, C<UniqueConflict-E<gt>attempt>
degrades to a plain C<eval>, and the unit suite cannot tell a savepoint-guarded
conflict recovery apart from one that would abort the transaction on a real
PostgreSQL. That gap is why a broken recovery path stayed green for a long
time; see C<docs/QUALITY_PROGRAM.md>.

=head1 SUBROUTINES/METHODS

=head2 dbh

Returns a handle-shaped hash whose C<AutoCommit> is false only inside a
transaction.

=head2 transaction_depth

Current transaction depth, delegated to the schema.

=head2 txn_depth

The same depth under a name DBIx::Class does not have, for the callers that
still use it. To be removed.

=head2 svp_begin

Establishes a savepoint, minting C<savepoint_N> when no name is given, and
snapshots the schema state. Returns 1, as DBD::Pg does; the name is the
last of C<savepoints>.

=head2 svp_rollback

Restores the snapshot taken at the named savepoint (or the most recent),
discards everything established after it, keeps the savepoint itself,
and clears the aborted state.

=head2 svp_release

Releases the named savepoint (or the most recent) and everything after it.

=head2 reset_savepoints

Empties the stack. Used when a transaction ends.

=head1 DIAGNOSTICS

Croaks when asked to roll back or release a savepoint that is not on the
stack, which is what PostgreSQL does (through
L<GPForum::Test::BareStorage/savepoint_index>).

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Test::BareStorage>, L<GPForum::Test::Dbh>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Models only the savepoint surface the application uses.

=head1 AUTHOR

Giacomo Picchiarelli

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Giacomo Picchiarelli. BSD-3-Clause.

=cut
