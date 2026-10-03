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

const my $PG_UNIQUE     => '23505';
const my $SQL_DBMS_NAME => 17;

# The indexes a conflict on a unique constraint can be reported under: its
# own and, when its table is partitioned, the index each partition attached
# to it (pg_inherits, recursively, for partitions of partitions). A row is
# stored in a partition, and PostgreSQL names the partition's index in the
# conflict -- notifications_default_pkey, notifications_2026_10_pkey -- not
# the parent's notifications_pkey. Partitions are attached while the
# application runs -- by the daily partition-maintenance timer and every
# migrate (ADR 0113) -- so the family is read when a conflict asks for it
# rather than remembered.
const my $INDEX_FAMILY_SQL => join q{ },
  'WITH RECURSIVE family (index_oid, index_name) AS (',
  'SELECT root.oid, root.relname::text FROM pg_class AS root',
  q{WHERE root.oid = to_regclass(?) AND root.relkind IN ('i', 'I')},
  'UNION ALL',
  'SELECT child.oid, child.relname::text FROM family',
  'JOIN pg_inherits AS link ON link.inhparent = family.index_oid',
  'JOIN pg_class AS child ON child.oid = link.inhrelid',
  ') SELECT index_name FROM family';

sub is_conflict ( $, $error ) {
    if ( !_has_text($error) ) {
        return 0;
    }

    return _matches_unique($error);
}

# A unique violation of this constraint and no other. Stores accept a
# conflict on the row they were writing and rethrow one on any other key, so
# the name has to be matched; on a partitioned table PostgreSQL reports the
# name of the partition's index, which is matched through the catalog. A test
# double has no catalog, and its fake ORM raises the constraint's own name.
sub is_conflict_on ( $, $schema, $error, $constraint ) {
    if ( !_has_text($error) || !_has_text($constraint) ) {
        return 0;
    }

    # The server's sentence has to say it is a unique violation, as it has to
    # name the index: is_conflict reads the whole text, where a member's text
    # in the parameter values can say "unique constraint" on an error that is
    # none. An index row too large for its index names that index, and was
    # taken for a conflict on it.
    my $message = _server_message($error);
    if ( !_matches_unique($message) ) {
        return 0;
    }
    if ( _names_index( $message, $constraint ) ) {
        return 1;
    }
    for my $partition ( _partition_indexes( $schema, $constraint ) ) {
        if ( _names_index( $message, $partition ) ) {
            return 1;
        }
    }

    return 0;
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

    my $storage = _schema_storage($schema);
    if ( !$storage || !_storage_supports_savepoint($storage) ) {
        return $undefined;
    }

    return $storage;
}

sub _schema_storage ($schema) {
    my $undefined;

    if ( !$schema || !$schema->can('storage') ) {
        return $undefined;
    }

    return eval { return $schema->storage };
}

# The partitions' index names, read from the catalog the conflict came from.
# A schema without a PostgreSQL handle has none to give, and neither has a
# lookup that failed: the conflict is then matched on the constraint's own
# name alone and anything else is rethrown, which is where the callers stood
# before partitions were asked about.
sub _partition_indexes ( $schema, $constraint ) {
    my $dbh = _catalog_dbh($schema);
    if ( !$dbh ) {
        return ();
    }

    my $names = eval {
        return $dbh->selectcol_arrayref( $INDEX_FAMILY_SQL, undef,
            $constraint );
    };
    if ( ref $names ne 'ARRAY' ) {
        return ();
    }

    return grep { $_ ne $constraint } @{$names};
}

sub _catalog_dbh ($schema) {
    my $undefined;

    my $storage = _schema_storage($schema);
    if ( !$storage || !$storage->can('dbh') ) {
        return $undefined;
    }

    my $dbh  = eval { return $storage->dbh };
    my $dbms = eval { return $dbh->get_info($SQL_DBMS_NAME) } // q{};
    if ( $dbms ne 'PostgreSQL' ) {
        return $undefined;
    }

    return $dbh;
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

# The server's own sentence: the error's first line, without the statement
# and parameter values DBI appends to it when no DETAIL line follows. The
# DETAIL line and those values carry the row's data, where a member's text
# could spell any constraint's name.
sub _server_message ($error) {
    my ($message) = split m/\n/msx, "$error";
    $message //= q{};
    $message =~ s/[ ] [[]for [ ] Statement [ ] .*//msx;

    return $message;
}

# A whole identifier, however the message quotes it: posts_pkey is not a
# conflict on thread_posts_pkey, nor notifications_pkey one on
# notifications_pkey_old.
sub _names_index ( $message, $name ) {
    return $message =~ m/(?<![[:word:]\$]) \Q$name\E (?![[:word:]\$])/msx
      ? 1
      : 0;
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
(C<pg_inherits>) when the error does not name the constraint itself.

C<attempt> wraps an insert attempt in a PostgreSQL savepoint when the schema is
inside an open transaction, so a unique violation does not abort the outer
C<txn_do>. Fake schemas without a live DBI handle keep the plain C<eval>
behavior.

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
C<is_conflict_on> costs one catalog query when the error names an index other
than the constraint itself.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
