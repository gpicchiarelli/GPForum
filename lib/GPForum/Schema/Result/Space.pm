# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::Space;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('spaces');

__PACKAGE__->add_columns(
    space_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    slug => {
        data_type   => 'text',
        is_nullable => 0,
    },
    title => {
        data_type   => 'text',
        is_nullable => 0,
    },
    description => {
        data_type     => 'text',
        default_value => q{},
        is_nullable   => 0,
    },
    visibility => {
        data_type     => 'text',
        default_value => 'public',
        is_nullable   => 0,
    },
    position => {
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

__PACKAGE__->set_primary_key('space_id');
__PACKAGE__->add_unique_constraint( spaces_slug_key => ['slug'] );
__PACKAGE__->has_many(
    categories => 'GPForum::Schema::Result::Category',
    'space_id'
);

1;
