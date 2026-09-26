# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::PartitionRegistry;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('partition_registry');

__PACKAGE__->add_columns(
    table_name => {
        data_type   => 'text',
        is_nullable => 0,
    },
    partition_name => {
        data_type   => 'text',
        is_nullable => 0,
    },
    range_start => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    range_end => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    state => {
        data_type     => 'text',
        default_value => 'planned',
        is_nullable   => 0,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    detached_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
    archived_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key( 'table_name', 'partition_name' );

1;

__END__

=head1 NAME

GPForum::Schema::Result::PartitionRegistry - Planned partition windows.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $rows = $schema->resultset('PartitionRegistry');

=head1 DESCRIPTION

Maps the PostgreSQL C<partition_registry> table used to record planned,
created, detached, archived, and dropped range partitions of C<event_log>,
C<audit_log>, and C<notifications>.

Rows are written by L<GPForum::Service::Operations::PartitionLifecycle>, which
upserts C<state = 'created'> on the primary key
C<(table_name, partition_name)> as it creates each monthly partition, and by
C<migrations/038_monthly_log_partitions.sql> for the partitions a fresh
install starts with. C<range_start> and C<range_end> are UTC month boundaries.

=head1 SUBROUTINES/METHODS

This result class exposes the standard DBIx::Class accessors for the mapped
columns. It does not add application methods.

=head1 DIAGNOSTICS

Database errors are raised by DBIx::Class.

=head1 CONFIGURATION AND ENVIRONMENT

Uses the application's PostgreSQL connection.

=head1 DEPENDENCIES

Uses L<DBIx::Class::Core>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The result class maps rows only. C<CREATE TABLE ... PARTITION OF> is issued by
L<GPForum::Service::Operations::PartitionLifecycle> over the same connection,
because partition DDL cannot be expressed through DBIx::Class. Detach,
archive, and drop transitions stay operator-owned, so states beyond C<created>
are recommendations until an operator records them.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
