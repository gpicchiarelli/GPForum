# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::EventLog;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

use GPForum::Schema::JsonColumn;

our $VERSION = '0.001';

__PACKAGE__->table('event_log');

__PACKAGE__->add_columns(
    event_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    event_type => {
        data_type   => 'text',
        is_nullable => 0,
    },
    schema_version => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    aggregate_type => {
        data_type   => 'text',
        is_nullable => 0,
    },
    aggregate_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    aggregate_version => {
        data_type     => 'bigint',
        default_value => 1,
        is_nullable   => 0,
    },
    actor_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    correlation_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    causation_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    idempotency_key => {
        data_type   => 'text',
        is_nullable => 0,
    },
    payload => {
        data_type     => 'jsonb',
        default_value => '{}',
        is_nullable   => 0,
    },
    metadata => {
        data_type     => 'jsonb',
        default_value => '{}',
        is_nullable   => 0,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
);

GPForum::Schema::JsonColumn->inflate_json_columns(__PACKAGE__);

__PACKAGE__->set_primary_key( 'event_id', 'created_at' );

1;

__END__

=head1 NAME

GPForum::Schema::Result::EventLog - Durable domain event record.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $events = $schema->resultset('EventLog');

=head1 DESCRIPTION

Maps append-only domain events used by GPForum workflows.

=head1 SUBROUTINES/METHODS

This result class exposes DBIx::Class result methods.

=head1 DIAGNOSTICS

Validation and storage errors are reported by DBIx::Class.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables are read.

=head1 DEPENDENCIES

Uses L<DBIx::Class::Core> through L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Event payload schemas are introduced incrementally by workflow services.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
