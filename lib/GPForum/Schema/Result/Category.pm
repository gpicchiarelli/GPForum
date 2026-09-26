# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::Category;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('categories');

__PACKAGE__->add_columns(
    category_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
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

__PACKAGE__->set_primary_key('category_id');
__PACKAGE__->add_unique_constraint(
    categories_space_slug_key => [ 'space_id', 'slug' ] );
__PACKAGE__->belongs_to(
    space => 'GPForum::Schema::Result::Space',
    'space_id'
);
__PACKAGE__->has_many(
    threads => 'GPForum::Schema::Result::Thread',
    'category_id'
);
__PACKAGE__->might_have(
    stats => 'GPForum::Schema::Result::CategoryStat',
    'category_id'
);

1;
