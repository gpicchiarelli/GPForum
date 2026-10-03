# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::X::Conflict;

use Const::Fast;
use Mojo::Base 'GPForum::X', -signatures;
use v5.40;

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

# The constraint or index the server's message names, when it names one. On a
# partitioned table that is the partition's index (notifications_2026_10_pkey),
# not the parent's constraint: ask `on` rather than compare this.
has 'constraint';

# The schema the conflict came from: `on` reads its catalog for the indexes
# of the constraint's partitions. Undef in a test double, where only the
# constraint's own name matches.
has 'schema';

# The conflict an error is, or undef when it is none. Only the server's own
# sentence decides: a member's text in the parameter values DBI appends can
# say "unique constraint" on an error that is no conflict at all.
sub from_error ( $class, $error, $schema = undef ) {
    if ( !$error ) {
        return undef;
    }
    if ( my $conflict = $class->caught($error) ) {
        return $conflict;
    }

    my $message = $class->server_message($error);
    if ( !$class->reports_unique($message) ) {
        return undef;
    }

    return $class->new(
        message    => "$error",
        cause      => $error,
        constraint => _reported_constraint($message),
        schema     => $schema,
    );
}

# A unique violation of this constraint and no other. Stores accept a
# conflict on the row they were writing and rethrow one on any other key, so
# the name has to be matched; on a partitioned table PostgreSQL reports the
# name of the partition's index, which is matched through the catalog. A test
# double has no catalog, and its fake ORM raises the constraint's own name.
sub on ( $self, $constraint ) {
    if ( !defined $constraint || !length $constraint ) {
        return 0;
    }

    # The server's sentence has to say it is a unique violation, as it has to
    # name the index: the whole text can say "unique constraint" in a
    # member's parameter values on an error that is none. An index row too
    # large for its index names that index, and was taken for a conflict on
    # it.
    my $message = $self->server_message( $self->message );
    if ( !$self->reports_unique($message) ) {
        return 0;
    }
    if ( _names_index( $message, $constraint ) ) {
        return 1;
    }
    for my $partition ( _partition_indexes( $self->schema, $constraint ) ) {
        if ( _names_index( $message, $partition ) ) {
            return 1;
        }
    }

    return 0;
}

sub reports_unique ( $, $text ) {

    # Delimited, not a bare substring. m/23505/ matched those five digits
    # anywhere in the text, so an unrelated failure that happened to mention a
    # byte offset, row count or id containing them was classified as a unique
    # violation -- and the recovery path swallows what it classifies.
    if ( $text =~ m/(?<![[:digit:]]) $PG_UNIQUE (?![[:digit:]])/msx ) {
        return 1;
    }
    if ( $text =~ m/unique [ ] constraint/imsx ) {
        return 1;
    }
    if ( $text =~ m/duplicate [ ] key/imsx ) {
        return 1;
    }

    return 0;
}

# The server's own sentence: the error's first line, without the statement
# and parameter values DBI appends to it when no DETAIL line follows. The
# DETAIL line and those values carry the row's data, where a member's text
# could spell any constraint's name.
sub server_message ( $, $error ) {
    my ($message) = split m/\n/msx, "$error";
    $message //= q{};
    $message =~ s/[ ] [[]for [ ] Statement [ ] .*//msx;

    return $message;
}

# The name PostgreSQL quotes in "violates unique constraint "NAME"", which on
# a partitioned table is the partition's index; undef when the text does not
# say.
sub _reported_constraint ($message) {
    if ( $message =~ m/unique [ ] constraint [ ] "([^"]+)"/imsx ) {
        return $1;
    }

    return undef;
}

# A whole identifier, however the message quotes it: posts_pkey is not a
# conflict on thread_posts_pkey, nor notifications_pkey one on
# notifications_pkey_old.
sub _names_index ( $message, $name ) {
    return $message =~ m/(?<![[:word:]\$]) \Q$name\E (?![[:word:]\$])/msx
      ? 1
      : 0;
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
    if ( !$schema || !$schema->can('storage') ) {
        return undef;
    }

    my $storage = eval { return $schema->storage };
    if ( !$storage || !$storage->can('dbh') ) {
        return undef;
    }

    my $dbh  = eval { return $storage->dbh };
    my $dbms = eval { return $dbh->get_info($SQL_DBMS_NAME) } // q{};
    if ( $dbms ne 'PostgreSQL' ) {
        return undef;
    }

    return $dbh;
}

1;

__END__

=head1 NAME

GPForum::X::Conflict - A unique constraint refused a write.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my ( $row, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $schema, sub { return $rs->create($values) } );
    my $conflict = GPForum::X::Conflict->caught($error);
    if ( $conflict && $conflict->on('posts_pkey') ) {
        return $self->_existing($values);
    }

=head1 DESCRIPTION

A PostgreSQL unique violation (SQLSTATE 23505), or the same refusal raised by
a test double. L<GPForum::Infrastructure::UniqueConflict> makes them:
C<attempt> wraps a unique violation its code raised, and C<throw> raises one
for a test double.

It stringifies to the original error text, the DBI message included, so the
stores that still match a constraint name with C<index($error, ...)> or call
C<UniqueConflict-E<gt>is_conflict($error)> read it as before. Its
C<failure_type> is the default, C<transient>, which is what the outbox's
regexes gave that text.

=head1 SUBROUTINES/METHODS

=head2 from_error

Class method: takes an error and optionally the schema it came from, and
returns the conflict it is -- a new one carrying the error as C<cause>, or the
error itself when it already is one -- or undef when the server's sentence
does not report a unique violation.

=head2 on

True when this is a conflict on the named constraint: the server's message
reports a unique violation and names the constraint or, on PostgreSQL, the
index of one of its table's partitions, read from the schema's catalog.

=head2 reports_unique

True when a text reports a unique violation: SQLSTATE 23505 as a whole
number, "unique constraint" or "duplicate key".

=head2 server_message

The server's own sentence in an error: its first line, without the statement
and parameter values DBI appends.

=head1 DIAGNOSTICS

None of its own.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::X>, L<Const::Fast>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The exception holds the schema it came from for as long as it lives; it
should be handled, not stored. C<on> costs one catalog query when the error
names an index other than the constraint itself.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
