package GPForum::Schema::Result::AuditLog;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('audit_log');

__PACKAGE__->add_columns(
    audit_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    action => {
        data_type   => 'text',
        is_nullable => 0,
    },
    schema_version => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    actor_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    target_type => {
        data_type   => 'text',
        is_nullable => 1,
    },
    target_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    correlation_id => {
        data_type   => 'uuid',
        is_nullable => 0,
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

__PACKAGE__->set_primary_key( 'audit_id', 'created_at' );

1;

__END__

=head1 NAME

GPForum::Schema::Result::AuditLog - Append-only audit record.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $audit = $schema->resultset('AuditLog');

=head1 DESCRIPTION

Maps append-only audit records for security-sensitive GPForum workflows.

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

Audit retention policy is added in an operations milestone.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
