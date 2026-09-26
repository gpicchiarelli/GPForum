# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::IdentityToken;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

use GPForum::Schema::JsonColumn;

our $VERSION = '0.001';

__PACKAGE__->table('identity_tokens');

__PACKAGE__->add_columns(
    token_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    user_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    token_type => {
        data_type   => 'text',
        is_nullable => 0,
    },
    token_hash => {
        data_type   => 'text',
        is_nullable => 0,
    },
    email_normalized => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    expires_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    used_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
    metadata => {
        data_type     => 'jsonb',
        default_value => '{}',
        is_nullable   => 0,
    },
);

GPForum::Schema::JsonColumn->inflate_json_columns(__PACKAGE__);

__PACKAGE__->set_primary_key('token_id');
__PACKAGE__->add_unique_constraint(
    identity_tokens_hash_key => ['token_hash'] );
__PACKAGE__->belongs_to(
    user => 'GPForum::Schema::Result::User',
    'user_id',
    { join_type => 'left' }
);

1;
