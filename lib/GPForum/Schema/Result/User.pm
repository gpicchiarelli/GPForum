# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::User;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

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
    preferred_locale => {
        data_type     => 'text',
        default_value => 'en',
        is_nullable   => 0,
    },
    preferred_theme => {
        data_type     => 'text',
        default_value => 'default',
        is_nullable   => 0,
    },
    preferred_timezone => {
        data_type   => 'text',
        is_nullable => 1,
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
__PACKAGE__->has_many(
    identity_tokens => 'GPForum::Schema::Result::IdentityToken',
    'user_id'
);
__PACKAGE__->has_many(
    authored_threads => 'GPForum::Schema::Result::Thread',
    'author_user_id'
);
__PACKAGE__->has_many(
    authored_posts => 'GPForum::Schema::Result::Post',
    'author_user_id'
);
__PACKAGE__->has_many(
    post_revisions => 'GPForum::Schema::Result::PostRevision',
    'editor_user_id'
);
__PACKAGE__->has_many(
    thread_read_states => 'GPForum::Schema::Result::ThreadReadState',
    'user_id'
);
__PACKAGE__->has_many(
    read_marker_deltas => 'GPForum::Schema::Result::UserReadMarkerDelta',
    'user_id'
);
__PACKAGE__->has_many(
    bookmarks => 'GPForum::Schema::Result::Bookmark',
    'user_id'
);
__PACKAGE__->has_many(
    subscriptions => 'GPForum::Schema::Result::Subscription',
    'user_id'
);
__PACKAGE__->has_many(
    authored_mentions => 'GPForum::Schema::Result::Mention',
    'actor_id'
);
__PACKAGE__->has_many(
    mentions => 'GPForum::Schema::Result::Mention',
    'mentioned_user_id'
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
