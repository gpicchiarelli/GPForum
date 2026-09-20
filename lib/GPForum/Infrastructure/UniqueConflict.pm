package GPForum::Infrastructure::UniqueConflict;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

our $VERSION = '0.001';

const my $PG_UNIQUE    => '23505';
const my $SAVEPOINT_ID => 'gpforum_unique_conflict';

sub is_conflict {
    my ( undef, $error ) = @_;

    if ( !_has_text($error) ) {
        return 0;
    }

    return _matches_unique($error);
}

sub throw {
    my ( undef, $constraint ) = @_;

    croak _message($constraint);
}

sub rethrow {
    my ( undef, $error ) = @_;

    croak $error;
}

sub attempt {
    my ( undef, $schema, $code ) = @_;

    my $storage = _savepoint_storage($schema);
    if ($storage) {
        $storage->svp_begin($SAVEPOINT_ID);
    }

    my $value = eval { return $code->() };
    my $error = $EVAL_ERROR;
    _finish_savepoint( $storage, $error );

    return ( $value, $error );
}

sub _finish_savepoint {
    my ( $storage, $error ) = @_;

    if ( !$storage ) {
        return;
    }
    if ($error) {
        $storage->svp_rollback($SAVEPOINT_ID);
        return;
    }

    $storage->svp_release($SAVEPOINT_ID);
    return;
}

sub _savepoint_storage {
    my ($schema) = @_;

    if ( !$schema || !$schema->can('storage') ) {
        return;
    }

    my $storage = eval { return $schema->storage };
    if ( !$storage || !_storage_supports_savepoint($storage) ) {
        return;
    }

    return $storage;
}

sub _storage_supports_savepoint {
    my ($storage) = @_;

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

sub _matches_unique {
    my ($error) = @_;

    if ( $error =~ m/$PG_UNIQUE/msx ) {
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

sub _message {
    my ($constraint) = @_;

    my $name = $constraint;
    if ( !_has_text($name) ) {
        $name = 'unknown';
    }

    return
      "duplicate key value violates unique constraint \"$name\" ($PG_UNIQUE)";
}

sub _has_text {
    my ($value) = @_;

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
