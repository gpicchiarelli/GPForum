# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::BareStorage;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# The words DBIx::Class's own failure starts with when it cannot connect.
const my $NO_DATABASE =>
  'DBI Connection failed: the test double has no database';

const my $OUTSIDE_TRANSACTION =>
  q{You can't use savepoints outside a transaction};

# What DBD::Pg's pg_savepoint, pg_release and pg_rollback_to return.
const my $DRIVER_ANSWER => 1;

# optional: a double without a database has no handle, as dbh_of reports for
# a schema that cannot connect.
has dbh   => undef;
has debug => 0;

# DBIx::Class::Storage keeps its transaction depth under this name and no
# other: a storage double that also answered another name would let code ask
# for a depth the real storage never reports.
has transaction_depth => 0;

# optional: DBIx::Class's query statistics object, set by whoever turns
# debugging on.
has debugobj => undef;

# DBIx::Class runs the code with the storage and a connected handle, and fails
# when it cannot connect; so does the double without a database.
sub dbh_do {
    my ( $self, $code, @arguments ) = @_;

    my $dbh = $self->dbh;
    croak $NO_DATABASE if !$dbh;

    return $code->( $self, $dbh, @arguments );
}

# DBIx::Class's savepoint stack: a name minted as savepoint_N when none is
# given, a rollback that keeps the named savepoint and drops the later ones,
# a release that drops it too, and the most recent savepoint when a rollback
# or a release names none. Savepoints exist only inside a transaction, and
# each needs a connection. Only the names are kept; a subclass that holds
# rows also puts them back on rollback.
has savepoints => sub { return []; };

# DBIx::Class returns what the driver's savepoint call returns, not the name:
# DBD::Pg answers 1. A caller reads the minted name back off savepoints, as
# UniqueConflict does; one that took the return value for the name would get
# 1 on PostgreSQL, so it gets 1 here too.
sub svp_begin {
    my ( $self, $name ) = @_;

    $self->assert_savepoint_usable;
    $name //= 'savepoint_' . scalar @{ $self->savepoints };
    push @{ $self->savepoints }, $name;

    return $DRIVER_ANSWER;
}

sub svp_rollback {
    my ( $self, $name ) = @_;

    my $index =
      $self->savepoint_index( $self->savepoint_named( $name, 'rollback' ) );
    splice @{ $self->savepoints }, $index + 1;

    return $DRIVER_ANSWER;
}

sub svp_release {
    my ( $self, $name ) = @_;

    my $index =
      $self->savepoint_index( $self->savepoint_named( $name, 'release' ) );
    splice @{ $self->savepoints }, $index;

    return $DRIVER_ANSWER;
}

# DBIx::Class refuses a savepoint outside a transaction before it touches the
# connection.
sub assert_savepoint_usable {
    my ($self) = @_;

    croak $OUTSIDE_TRANSACTION if !$self->transaction_depth;
    croak $NO_DATABASE         if !$self->dbh;

    return;
}

# The savepoint a rollback or a release acts on: the one named, else the most
# recent, refused as DBIx::Class refuses it when there is none.
sub savepoint_named {
    my ( $self, $name, $action ) = @_;

    $self->assert_savepoint_usable;
    return $name if defined $name;

    my $latest = $self->savepoints->[-1];
    croak "No savepoints to $action" if !defined $latest;

    return $latest;
}

sub savepoint_index {
    my ( $self, $name ) = @_;

    my $names = $self->savepoints;
    for my $index ( reverse 0 .. $#{$names} ) {
        return $index if $names->[$index] eq $name;
    }

    croak "Savepoint '$name' does not exist";
}

1;

__END__

=head1 NAME

GPForum::Test::BareStorage - The DBIx::Class storage surface, for doubles.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    package GPForum::Test::ThingStorage;
    use Mojo::Base 'GPForum::Test::BareStorage';

    my $storage = GPForum::Test::ThingStorage->new;           # no database
    $storage->dbh;                                             # undef
    GPForum::Test::ThingStorage->new( dbh => $handle )
      ->dbh_do( sub { my ( $storage, $dbh ) = @_; ... } );

=head1 DESCRIPTION

What every L<DBIx::Class::Storage::DBI> answers and the application asks a
storage for: C<dbh>, C<dbh_do>, C<transaction_depth>, C<debug>, C<debugobj>
and the C<svp_*> savepoint methods, under the names DBIx::Class gives them. A storage double built on it answers all of them,
so code does not need to ask whether it holds a real storage.

A double without a database has no handle: C<dbh> is undef, as
L<GPForum::Infrastructure::Storage/dbh_of> reports for a schema that cannot
connect, C<dbh_do> fails as DBIx::Class does when it cannot connect, and the
savepoint methods fail outside a transaction as DBIx::Class's do. With a
handle the savepoint stack keeps names only.

=head1 SUBROUTINES/METHODS

=head2 dbh_do

Runs the code with the storage, the handle and the arguments; croaks when
there is no handle.

=head2 svp_begin

Pushes a savepoint name, minting C<savepoint_N> when none is given, and
returns 1 as DBD::Pg does: the name is read back off C<savepoints>.

=head2 svp_rollback

Drops the savepoints after the named one, or the most recent, keeping it.

=head2 svp_release

Drops the named savepoint, or the most recent, and the later ones.

=head2 assert_savepoint_usable

Croaks outside a transaction, and without a handle, as DBIx::Class does.

=head2 savepoint_named

The savepoint a rollback or release acts on: the named one, else the most
recent.

=head2 savepoint_index

Where the named savepoint is on the stack; croaks when it is not there.

=head1 DIAGNOSTICS

C<DBI Connection failed: the test double has no database>, C<You can't use
savepoints outside a transaction>, C<No savepoints to release> (or
C<rollback>), and C<Savepoint 'NAME' does not exist> for a name not on the
stack, worded as DBIx::Class words them.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>, L<Carp>, L<Const::Fast>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

No transaction or reconnection is modelled here, and a rollback to a
savepoint puts no row back; L<GPForum::Test::Storage> does.

=head1 AUTHOR

Giacomo Picchiarelli

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Giacomo Picchiarelli. BSD-3-Clause.

=cut
