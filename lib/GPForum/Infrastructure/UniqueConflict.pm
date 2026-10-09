# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Infrastructure::UniqueConflict;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Infrastructure::Storage;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $PG_UNIQUE => '23505';

sub is_conflict ( $, $error ) {
    if ( !_has_text($error) ) {
        return 0;
    }

    return GPForum::X::Conflict->reports_unique($error);
}

# A unique violation of this constraint and no other, partitions included:
# GPForum::X::Conflict->on, for an error that may not be an exception yet.
sub is_conflict_on ( $, $schema, $error, $constraint ) {
    if ( !_has_text($error) || !_has_text($constraint) ) {
        return 0;
    }

    return GPForum::X::Conflict->new( message => "$error", schema => $schema )
      ->on($constraint);
}

sub throw ( $, $constraint ) {
    my ( undef, $file, $line ) = caller;
    croak GPForum::X::Conflict->new(
        message    => _message($constraint),
        constraint => _has_text($constraint) ? $constraint : undef,
        location   => "$file line $line",
    );
}

sub rethrow ( $, $error ) {
    croak $error;
}

sub attempt ( $, $schema, $code ) {
    my $storage   = _savepoint_storage($schema);
    my $savepoint = _begin_savepoint($storage);

    my ( $value, $error );
    try {
        $value = $code->();
    }
    catch ($caught) {
        $error = $caught;
    };
    _finish_savepoint( $storage, $savepoint, $error );

    # A unique violation comes back as a GPForum::X::Conflict that stringifies
    # to the original text, so the stores matching that text keep working and
    # a caller can ask $error->on($constraint). Any other error, and no error,
    # comes back as it was.
    return ( $value,
        GPForum::X::Conflict->from_error( $error, $schema ) // $error );
}

# DBIx::Class mints the name so that nesting works. A fixed name does not:
# svp_rollback deliberately leaves the named savepoint on the storage stack
# ("a rollback doesn't remove the named savepoint, only everything after it"),
# so with one shared name a later svp_release matches an inner leftover rather
# than its own savepoint and the stack stays skewed for the whole transaction.
sub _begin_savepoint ($storage) {
    if ( !$storage ) {
        return undef;
    }

    $storage->svp_begin;

    return $storage->savepoints->[-1];
}

sub _finish_savepoint ( $storage, $savepoint, $error ) {
    if ( !$storage || !defined $savepoint ) {
        return;
    }

    if ($error) {
        _quietly( $storage, 'svp_rollback', $savepoint );
    }

    # PostgreSQL keeps a rolled-back savepoint established, and DBIx::Class
    # keeps it on its stack, so the release is required on both paths. Without
    # it every conflict leaks a subtransaction for the rest of the enclosing
    # transaction.
    _quietly( $storage, 'svp_release', $savepoint );

    return;
}

# A savepoint teardown must never replace the caller's error with its own: if
# the connection is already gone the original conflict is the useful one.
sub _quietly ( $storage, $method, $savepoint ) {
    my $done = 0;
    try {
        $storage->$method($savepoint);
        $done = 1;
    }
    catch ($error) {
        $done = 0;
    };

    return $done;
}

# A savepoint only inside a transaction: outside one there is nothing for a
# conflict to abort, and a schema without storage -- a test double -- has no
# savepoints to take.
sub _savepoint_storage ($schema) {
    my $storage = GPForum::Infrastructure::Storage->storage_of($schema);
    if ( !blessed $storage || !$storage->can('svp_begin') ) {
        return undef;
    }

    my $dbh = GPForum::Infrastructure::Storage->dbh_of($schema);
    if ( !$dbh || $dbh->{AutoCommit} ) {
        return undef;
    }

    return $storage;
}

sub _message ($constraint) {
    my $name = $constraint;
    if ( !_has_text($name) ) {
        $name = 'unknown';
    }

    return
      "duplicate key value violates unique constraint \"$name\" ($PG_UNIQUE)";
}

sub _has_text ($value) {
    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Infrastructure::UniqueConflict - Detect PostgreSQL unique races.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my ( $row, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $schema,
        sub { return $rs->create($row) },
    );
    if ( GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        return $existing;
    }

=head1 DESCRIPTION

Recognizes PostgreSQL C<23505> unique violations and the equivalent fake-store
messages used in tests. Stores catch the conflict and reload the winning row
instead of returning a 500.

C<is_conflict_on> narrows that to one constraint. On a partitioned table
PostgreSQL names the partition's index in the conflict, not the table's
constraint, so the partitions' index names are read from the catalog
(C<pg_inherits>) when the error does not name the constraint itself. The
rules live in L<GPForum::X::Conflict>, which C<attempt> returns for a unique
violation.

C<attempt> wraps an insert attempt in a PostgreSQL savepoint when the schema is
inside an open transaction, so a unique violation does not abort the outer
C<txn_do>. Outside a transaction, or on a fake schema without a live DBI
handle, the code runs without one.

=head1 SUBROUTINES/METHODS

=head2 is_conflict

True when the error text is a unique constraint violation.

=head2 is_conflict_on

Takes the schema, the error and a constraint name. True when the error is a
unique violation of that constraint: the server's message (not its DETAIL,
the statement or its parameter values) reports a unique violation and names
the constraint itself or, on PostgreSQL, the index of one of its table's
partitions. Call it after C<attempt>, whose savepoint leaves the transaction
able to run the catalog lookup; a lookup that fails, or a schema with no
PostgreSQL handle, leaves only the constraint's own name to match.

=head2 attempt

Runs a code reference and returns C<($value, $error)>. On a live PostgreSQL
transaction, the attempt is guarded by a savepoint. A unique violation comes
back as a L<GPForum::X::Conflict> that stringifies to the original error text
and carries the schema, so C<< $error->on($constraint) >> can ask about
partitions; any other error comes back unchanged, and C<$error> is undef when
the code did not die.

=head2 throw

Raises a L<GPForum::X::Conflict> for test fakes, whose text is a
PostgreSQL-shaped unique violation naming the constraint.

=head2 rethrow

Propagates a non-unique error with croak.

=head1 DIAGNOSTICS

C<throw> croaks a L<GPForum::X::Conflict> whose message is a PostgreSQL-shaped
unique violation string.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Carp>, L<Const::Fast>, L<Mojo::Base>,
L<GPForum::Infrastructure::Storage> for the savepoint probe and
L<GPForum::X::Conflict>, which holds the matching rules.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Detection is string-based so non-PostgreSQL drivers must raise a matching
error text. Savepoints are used only when C<AutoCommit> is false.
C<is_conflict_on> costs one catalog query when the error names an index other
than the constraint itself.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
