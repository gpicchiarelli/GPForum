# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::Credential;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('credentials');

__PACKAGE__->add_columns(
    id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    user_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    type => {
        data_type   => 'text',
        is_nullable => 0,
    },
    secret_hash => {
        data_type   => 'text',
        is_nullable => 0,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    revoked_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

# No unique constraint on user_id. The database has one only among active
# passwords -- idx_credentials_active_password_unique, WHERE revoked_at IS NULL
# AND type = 'password' -- and DBIx::Class cannot express a partial one.
# Declared here, it would let find() treat user_id alone as a unique key and
# hand back a revoked credential. CredentialStore matches the index name in
# the database's error to recognise the conflict.
__PACKAGE__->belongs_to( user => 'GPForum::Schema::Result::User', 'user_id' );

1;

__END__

=head1 NAME

GPForum::Schema::Result::Credential - User credential record.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $credentials = $schema->resultset('Credential');

=head1 DESCRIPTION

Maps password and future MFA credential records without embedding credential
workflow logic in ORM objects.

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

Only credential persistence metadata is mapped in this milestone.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
