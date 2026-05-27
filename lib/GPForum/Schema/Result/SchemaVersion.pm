package GPForum::Schema::Result::SchemaVersion;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('schema_versions');

__PACKAGE__->add_columns(
    version => {
        data_type   => 'text',
        is_nullable => 0,
    },
    description => {
        data_type   => 'text',
        is_nullable => 0,
    },
    checksum => {
        data_type   => 'text',
        is_nullable => 0,
    },
    applied_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('version');

1;

__END__

=head1 NAME

GPForum::Schema::Result::SchemaVersion - Applied migration record.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $versions = $schema->resultset('SchemaVersion');

=head1 DESCRIPTION

Maps the append-only C<schema_versions> table used to record applied database
migrations.

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

Only migration metadata is mapped in this milestone.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
