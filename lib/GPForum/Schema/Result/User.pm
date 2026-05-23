package GPForum::Schema::Result::User;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('users');

__PACKAGE__->add_columns(
    id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    username => {
        data_type   => 'text',
        is_nullable => 0,
    },
    display_name => {
        data_type   => 'text',
        is_nullable => 0,
    },
    email_normalized => {
        data_type   => 'text',
        is_nullable => 0,
    },
    password_hash => {
        data_type   => 'text',
        is_nullable => 0,
    },
    status => {
        data_type     => 'text',
        default_value => 'pending',
        is_nullable   => 0,
    },
    trust_level => {
        data_type     => 'integer',
        default_value => 0,
        is_nullable   => 0,
    },
    version => {
        data_type     => 'bigint',
        default_value => 1,
        is_nullable   => 0,
    },
    permission_version => {
        data_type     => 'bigint',
        default_value => 1,
        is_nullable   => 0,
    },
    email_verified_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    updated_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    deleted_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint( users_username_key => ['username'] );
__PACKAGE__->add_unique_constraint(
    users_email_normalized_key => ['email_normalized'] );

__PACKAGE__->has_many(
    credentials => 'GPForum::Schema::Result::Credential',
    'user_id'
);
__PACKAGE__->has_many(
    sessions => 'GPForum::Schema::Result::Session',
    'user_id'
);

1;

__END__

=head1 NAME

GPForum::Schema::Result::User - User security principal.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $users = $schema->resultset('User');

=head1 DESCRIPTION

Maps GPForum users as security principals, ownership anchors, and account
lifecycle records.

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

Registration workflow behavior is implemented outside this result class.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
