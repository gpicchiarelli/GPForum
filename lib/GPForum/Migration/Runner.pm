package GPForum::Migration::Runner;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Digest::SHA qw(sha256_hex);
use Mojo::Base -base;
use Mojo::File  qw(path);
use Time::HiRes qw(time);

use GPForum::Migration::Plan;

our $VERSION = '0.001';

const my $MILLISECONDS => 1_000;

has plan       => sub { return GPForum::Migration::Plan->new; };
has schema     => undef;
has applied_by => sub { return $ENV{USER} || 'gpforum'; };

sub pending {
    my ($self) = @_;

    my $applied = $self->applied_versions;

    return [ grep { !exists $applied->{ $_->{version} } }
          @{ $self->plan->summary } ];
}

sub applied_versions {
    my ($self) = @_;

    my $rows = eval {
        return $self->_dbh->selectall_arrayref(
            'SELECT version FROM schema_versions',
            { Slice => {} } );
    };

    return {} if !$rows;

    my %applied = map { $_->{version} => 1 } @{$rows};

    return \%applied;
}

sub apply_pending {
    my ($self) = @_;

    my @applied;

    for my $migration ( @{ $self->pending } ) {
        push @applied, $self->apply_migration($migration);
    }

    return \@applied;
}

sub apply_migration {
    my ( $self, $migration ) = @_;

    my $sql      = path( $migration->{file} )->slurp;
    my $checksum = sha256_hex($sql);
    my $started  = time;

    $self->_execute($sql);

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

sub _record_schema_version {
    my ( $self, $migration, $checksum ) = @_;

    $self->_execute(
'INSERT INTO schema_versions (version, description, checksum) VALUES (?, ?, ?)',
        undef, $migration->{version}, $migration->{description}, $checksum
    );

    return;
}

sub _record_migration_safety {
    my ( $self, $migration, $checksum, $elapsed_ms ) = @_;

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

sub _dbh {
    my ($self) = @_;

    croak 'schema is required'
      if !defined $self->schema;

    return $self->schema->storage->dbh;
}

sub _execute {
    my ( $self, $statement, @arguments ) = @_;

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

=head1 DIAGNOSTICS

Throws exceptions for missing schema configuration and propagates DBI failures.

=head1 CONFIGURATION AND ENVIRONMENT

C<USER> is used as the default applied-by value.

=head1 DEPENDENCIES

Uses L<Digest::SHA>, L<Mojo::File>, L<Time::HiRes>, and
L<GPForum::Migration::Plan>.

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
