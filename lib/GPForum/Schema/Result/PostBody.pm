# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::PostBody;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('post_bodies');

__PACKAGE__->add_columns(
    body_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    post_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    body_format => {
        data_type     => 'text',
        default_value => 'markdown',
        is_nullable   => 0,
    },
    body_source => {
        data_type   => 'text',
        is_nullable => 0,
    },
    body_rendered_safe => {
        data_type   => 'text',
        is_nullable => 0,
    },
    source_hash => {
        data_type   => 'text',
        is_nullable => 0,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('body_id');
__PACKAGE__->belongs_to( post => 'GPForum::Schema::Result::Post', 'post_id' );
__PACKAGE__->has_many(
    revisions => 'GPForum::Schema::Result::PostRevision',
    'body_id'
);

1;
