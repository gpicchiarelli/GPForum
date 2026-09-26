# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::PostRevision;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('post_revisions');

__PACKAGE__->add_columns(
    revision_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    post_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    body_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    editor_user_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    revision_number => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    edit_reason => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('revision_id');
__PACKAGE__->add_unique_constraint(
    post_revisions_post_revision_number_key => [ 'post_id', 'revision_number' ]
);
__PACKAGE__->belongs_to( post => 'GPForum::Schema::Result::Post', 'post_id' );
__PACKAGE__->belongs_to(
    body => 'GPForum::Schema::Result::PostBody',
    'body_id'
);
__PACKAGE__->belongs_to(
    editor => 'GPForum::Schema::Result::User',
    'editor_user_id'
);

1;
