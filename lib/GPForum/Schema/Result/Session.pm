package GPForum::Schema::Result::Session;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('sessions');

__PACKAGE__->add_columns(
    session_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    user_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    session_hash => {
        data_type   => 'text',
        is_nullable => 0,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    last_seen_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    expires_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    revoked_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
    ip_hash => {
        data_type   => 'text',
        is_nullable => 1,
    },
    user_agent_hash => {
        data_type   => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('session_id');
__PACKAGE__->add_unique_constraint(
    sessions_session_hash_key => ['session_hash'] );
__PACKAGE__->belongs_to( user => 'GPForum::Schema::Result::User', 'user_id' );

1;

__END__

=head1 NAME

GPForum::Schema::Result::Session - Revocable server-side session record.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $sessions = $schema->resultset('Session');

=head1 DESCRIPTION

Maps distributed-safe, revocable session metadata. Raw session tokens are never
stored in this table.

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

Session creation and revocation workflows live in application services.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
