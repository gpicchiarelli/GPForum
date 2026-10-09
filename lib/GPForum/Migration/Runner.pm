# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Migration::Runner;

use Carp qw(croak);
use Const::Fast;
use Digest::SHA qw(sha256_hex);
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;
use Mojo::File  qw(path);
use Time::HiRes qw(time);

use GPForum::Migration::Plan;
use GPForum::X::Argument;
use GPForum::X::Check;

our $VERSION = '0.001';

const my $MILLISECONDS => 1_000;

# One fixed key for the whole migration surface. Session-level, not
# transaction-level: the migration files open and commit their own
# transactions, so a transaction-scoped lock would be released by the first
# COMMIT and leave the rest of the run unprotected.
const my $MIGRATION_LOCK_KEY => 4_021_970_001;

# A migration whose first line is this marker runs outside a transaction, one
# statement at a time. CREATE INDEX CONCURRENTLY needs that: PostgreSQL refuses
# it inside a transaction block, and a file sent whole is one, so every index
# so far was built under a lock that stopped writes to its table. Such a file
# holds plain statements, each ending with a semicolon at the end of a line,
# and each safe to run again: a failure part-way leaves the earlier ones
# applied and the migration unrecorded, so the next run repeats them.
const my $NO_TRANSACTION => qr{\A -- [ ] gpforum:no-transaction \b}msx;
const my $DOLLAR_QUOTE   => qr{[\$][\$]}msx;

__PACKAGE__->requires(qw(schema));
has plan       => sub { return GPForum::Migration::Plan->new; };
has applied_by => sub { return $ENV{USER} || 'gpforum'; };

sub pending ($self) {
    my $applied = $self->applied_versions;

    return [ grep { !exists $applied->{ $_->{version} } }
          @{ $self->plan->summary } ];
}

sub applied_versions ($self) {
    my $rows = $self->_select_leniently('SELECT version FROM schema_versions');

    return {} if !$rows;

    my %applied = map { $_->{version} => 1 } @{$rows};

    return \%applied;
}

# Two hosts deploying at once used to run the same migration twice, because
# nothing serialised them: each read an empty schema_versions and proceeded.
# The lock is held across the whole run, not per migration, so a second host
# waits for the first to finish rather than interleaving with it.
sub apply_pending ($self) {
    my $locked = $self->_lock;
    my @applied;
    my $failure;
    try {
        $self->verify_applied;
        for my $migration ( @{ $self->pending } ) {
            push @applied, $self->apply_migration($migration);
        }
    }
    catch ($error) {
        $failure = $error;
    };
    if ($locked) {
        $self->_unlock;
    }
    if ( defined $failure ) {
        croak $failure;
    }

    return \@applied;
}

# A checksum nobody compares is a comment. An applied migration whose file has
# changed since means the database and the tree disagree about what was run,
# which is exactly the state a checksum column exists to detect.
sub verify_applied ($self) {
    my $recorded = $self->recorded_checksums;
    if ( !%{$recorded} ) {
        return [];
    }

    my @drifted;
    for my $migration ( @{ $self->plan->summary } ) {
        my $stored = $recorded->{ $migration->{version} };
        next if !defined $stored;
        my $current = sha256_hex( path( $migration->{file} )->slurp );
        next if $current eq $stored;
        push @drifted,
          {
            version  => $migration->{version},
            recorded => $stored,
            current  => $current,
          };
    }

    if (@drifted) {
        GPForum::X::Check->throw(
            message => 'migration files changed after they were applied: '
              . join ', ',
            map { "$_->{version}" } @drifted
        );
    }

    return \@drifted;
}

sub recorded_checksums ($self) {
    my $rows =
      $self->_select_leniently('SELECT version, checksum FROM schema_versions');

    return {} if !$rows;

    return { map { $_->{version} => $_->{checksum} } @{$rows} };
}

# A database without schema_versions yet -- or none to be reached -- reads as
# one where nothing was applied: the rows, or undef.
sub _select_leniently ( $self, $sql ) {
    my $rows;
    try {
        $rows = $self->_dbh->selectall_arrayref( $sql, { Slice => {} } );
    }
    catch ($error) {
        $rows = undef;
    };

    return $rows;
}

sub _lock ($self) {
    my $dbh = $self->_dbh;
    if ( !$dbh || !$dbh->can('selectrow_array') ) {
        return 0;
    }

    return $self->_advisory( $dbh, 'pg_advisory_lock' );
}

sub _unlock ($self) {
    my $dbh = $self->_dbh;
    if ( !$dbh || !$dbh->can('selectrow_array') ) {
        return 0;
    }

    return $self->_advisory( $dbh, 'pg_advisory_unlock' );
}

# 1 when the advisory lock call ran, 0 when it died.
sub _advisory ( $self, $dbh, $function ) {
    my $done = 0;
    try {
        $dbh->selectrow_array( "SELECT $function(?)",
            undef, $MIGRATION_LOCK_KEY );
        $done = 1;
    }
    catch ($error) {
        $done = 0;
    };

    return $done;
}

sub apply_migration ( $self, $migration ) {
    my $sql      = path( $migration->{file} )->slurp;
    my $checksum = sha256_hex($sql);
    my $started  = time;

    if ( $sql =~ $NO_TRANSACTION ) {
        $self->_execute_each( $migration, $sql );
    }
    else {
        $self->_execute($sql);
    }

    my $elapsed_ms = int( ( time - $started ) * $MILLISECONDS );

    $self->_record_schema_version( $migration, $checksum );
    $self->_record_migration_safety( $migration, $checksum, $elapsed_ms );

    return {
        version           => $migration->{version},
        description       => $migration->{description},
        checksum          => $checksum,
        execution_time_ms => $elapsed_ms,
    };
}

sub _execute_each ( $self, $migration, $sql ) {
    my $dbh = $self->_dbh;
    if ( defined $dbh->{AutoCommit} && !$dbh->{AutoCommit} ) {
        GPForum::X::Argument->throw( message =>
"$migration->{version} runs outside a transaction, and one is open"
        );
    }

    for my $statement ( $self->statements($sql) ) {
        $self->_execute($statement);
    }

    return;
}

# The statements of a no-transaction migration: comment lines dropped, split
# at each semicolon that ends a line. A dollar-quoted body could hold such a
# semicolon, so it is refused rather than split wrongly.
sub statements ( $class, $sql ) {
    if ( $sql =~ $DOLLAR_QUOTE ) {
        GPForum::X::Argument->throw( message =>
              'a no-transaction migration holds plain statements: no $$ bodies'
        );
    }

    my $code = join "\n", grep { !/\A \s* --/msx } split /\n/msx, $sql;
    my @statements;
    for my $statement ( split /;[ \t]*$/msx, $code ) {
        $statement =~ s/\A \s+ | \s+ \z//gmsx;
        if ( length $statement ) {
            push @statements, $statement;
        }
    }

    return @statements;
}

sub _record_schema_version ( $self, $migration, $checksum ) {
    $self->_execute(
'INSERT INTO schema_versions (version, description, checksum) VALUES (?, ?, ?)',
        undef, $migration->{version}, $migration->{description}, $checksum
    );

    return;
}

sub _record_migration_safety ( $self, $migration, $checksum, $elapsed_ms ) {
    return if $migration->{version} lt '004';

    $self->_execute(
'INSERT INTO migration_safety (version, checksum, applied_by, execution_time_ms, requires_lock, reversible, rollback_sql_hash) VALUES (?, ?, ?, ?, ?, ?, ?)',
        undef,
        $migration->{version},
        $checksum,
        $self->applied_by,
        $elapsed_ms,
        0,
        0,
        q{}
    );

    return;
}

sub _dbh ($self) {
    return $self->schema->storage->dbh;
}

sub _execute ( $self, $statement, @arguments ) {
    my $dbh = $self->_dbh;

    if ( $dbh->can('execute_statement') ) {
        return $dbh->execute_statement( $statement, @arguments );
    }

    return $dbh->do( $statement, @arguments );
}

1;

__END__

=head1 NAME

GPForum::Migration::Runner - Applies GPForum SQL migrations.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $runner = GPForum::Migration::Runner->new(schema => $schema);
    my $applied = $runner->apply_pending;

=head1 DESCRIPTION

Discovers pending SQL migrations, applies them through DBI, records checksums in
C<schema_versions>, and records safety metadata once C<migration_safety> exists.

=head1 SUBROUTINES/METHODS

=head2 pending

Returns migrations not yet recorded in C<schema_versions>.

=head2 applied_versions

Returns a hash reference of applied migration versions.

=head2 apply_pending

Applies every pending migration in order.

=head2 apply_migration

Applies a single migration hash returned by L<GPForum::Migration::Plan>.

=head2 statements

The statements of a no-transaction migration, split at each semicolon that
ends a line, comment lines dropped. Croaks on a dollar-quoted body.

=head1 NO-TRANSACTION MIGRATIONS

A migration whose first line is C<-- gpforum:no-transaction> runs one
statement at a time, each in its own transaction, so it can build an index
with C<CREATE INDEX CONCURRENTLY> without stopping writes to the table. Each
statement must be safe to repeat: drop a half-built index first
(C<DROP INDEX CONCURRENTLY IF EXISTS>), because a failed concurrent build
leaves an invalid one behind.

=head1 DIAGNOSTICS

Throws L<GPForum::X::Argument> when built without a schema, when a
no-transaction migration meets an open transaction and when its SQL holds a
dollar-quoted body; L<GPForum::X::Check> when applied migration files have
changed since. DBI failures propagate.

=head1 CONFIGURATION AND ENVIRONMENT

C<USER> is used as the default applied-by value.

=head1 DEPENDENCIES

Uses L<Digest::SHA>, L<Mojo::File>, L<Time::HiRes>,
L<GPForum::Migration::Plan>, L<GPForum::X::Argument> and L<GPForum::X::Check>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Fresh database discovery treats an unreadable C<schema_versions> table as no
applied migrations.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
