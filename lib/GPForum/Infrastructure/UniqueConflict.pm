# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Infrastructure::UniqueConflict;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $PG_UNIQUE => '23505';

sub is_conflict ( $, $error ) {
    if ( !_has_text($error) ) {
        return 0;
    }

    return _matches_unique($error);
}

sub throw ( $, $constraint ) {
    croak _message($constraint);
}

sub rethrow ( $, $error ) {
    croak $error;
}

sub attempt ( $, $schema, $code ) {
    my $storage   = _savepoint_storage($schema);
    my $savepoint = _begin_savepoint($storage);

    my $value = eval { return $code->() };
    my $error = $EVAL_ERROR;
    _finish_savepoint( $storage, $savepoint, $error );

    return ( $value, $error );
}

# DBIx::Class mints the name so that nesting works. A fixed name does not:
# svp_rollback deliberately leaves the named savepoint on the storage stack
# ("a rollback doesn't remove the named savepoint, only everything after it"),
# so with one shared name a later svp_release matches an inner leftover rather
# than its own savepoint and the stack stays skewed for the whole transaction.
sub _begin_savepoint ($storage) {
    my $undefined;
    if ( !$storage ) {
        return $undefined;
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
    eval { $storage->$method($savepoint); return 1 } or return 0;

    return 1;
}

sub _savepoint_storage ($schema) {
    my $undefined;

    if ( !$schema || !$schema->can('storage') ) {
        return $undefined;
    }

    my $storage = eval { return $schema->storage };
    if ( !$storage || !_storage_supports_savepoint($storage) ) {
        return $undefined;
    }

    return $storage;
}

sub _storage_supports_savepoint ($storage) {
    if ( !$storage->can('svp_begin') ) {
        return 0;
    }
    if ( !$storage->can('dbh') ) {
        return 0;
    }

    my $dbh = eval { return $storage->dbh };
    if ( !$dbh ) {
        return 0;
    }
    if ( $dbh->{AutoCommit} ) {
        return 0;
    }

    return 1;
}

sub _matches_unique ($error) {

    # Delimited, not a bare substring. m/23505/ matched those five digits
    # anywhere in the text, so an unrelated failure that happened to mention a
    # byte offset, row count or id containing them was classified as a unique
    # violation -- and the recovery path swallows what it classifies.
    if ( $error =~ m/(?<![[:digit:]]) $PG_UNIQUE (?![[:digit:]])/msx ) {
        return 1;
    }
    if ( $error =~ m/unique [ ] constraint/imsx ) {
        return 1;
    }
    if ( $error =~ m/duplicate [ ] key/imsx ) {
        return 1;
    }

    return 0;
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

C<attempt> wraps an insert attempt in a PostgreSQL savepoint when the schema is
inside an open transaction, so a unique violation does not abort the outer
C<txn_do>. Fake schemas without a live DBI handle keep the plain C<eval>
behavior.

=head1 SUBROUTINES/METHODS

=head2 is_conflict

True when the error text is a unique constraint violation.

=head2 attempt

Runs a code reference and returns C<($value, $error)>. On a live PostgreSQL
transaction, the attempt is guarded by a savepoint.

=head2 throw

Raises a unique-violation error for test fakes.

=head2 rethrow

Propagates a non-unique error with croak.

=head1 DIAGNOSTICS

C<throw> croaks with a PostgreSQL-shaped unique violation string.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Carp>, L<Const::Fast>, L<English>, and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Detection is string-based so non-PostgreSQL drivers must raise a matching
error text. Savepoints are used only when C<AutoCommit> is false.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
