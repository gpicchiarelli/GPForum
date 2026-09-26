# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::ThreadCounter;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('thread_counters');

__PACKAGE__->add_columns(
    thread_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    reply_count => {
        data_type     => 'bigint',
        default_value => 0,
        is_nullable   => 0,
    },
    visible_reply_count => {
        data_type     => 'bigint',
        default_value => 0,
        is_nullable   => 0,
    },
    last_post_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    last_activity_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    version => {
        data_type     => 'bigint',
        default_value => 1,
        is_nullable   => 0,
    },
    reconciled_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('thread_id');
__PACKAGE__->belongs_to(
    thread => 'GPForum::Schema::Result::Thread',
    'thread_id'
);
__PACKAGE__->belongs_to(
    last_post => 'GPForum::Schema::Result::Post',
    'last_post_id',
    { join_type => 'left' }
);

1;
