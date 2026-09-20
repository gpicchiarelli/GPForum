package GPForum::Schema::Result::Credential;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

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
__PACKAGE__->add_unique_constraint(
    idx_credentials_active_password_unique => ['user_id'] );
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
