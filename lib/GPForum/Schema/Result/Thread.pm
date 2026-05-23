package GPForum::Schema::Result::Thread;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('threads');

__PACKAGE__->add_columns(
    thread_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    category_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    author_user_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    title => {
        data_type   => 'text',
        is_nullable => 0,
    },
    slug => {
        data_type   => 'text',
        is_nullable => 0,
    },
    pinned => {
        data_type     => 'boolean',
        default_value => 0,
        is_nullable   => 0,
    },
    visibility => {
        data_type     => 'text',
        default_value => 'public',
        is_nullable   => 0,
    },
    moderation_state => {
        data_type     => 'text',
        default_value => 'visible',
        is_nullable   => 0,
    },
    locked_at => {
        data_type   => 'timestamp with time zone',
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
    visibility_version => {
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
    deleted_by => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('thread_id');
__PACKAGE__->belongs_to(
    category => 'GPForum::Schema::Result::Category',
    'category_id'
);
__PACKAGE__->belongs_to(
    author => 'GPForum::Schema::Result::User',
    'author_user_id'
);
__PACKAGE__->belongs_to(
    deleted_by_user => 'GPForum::Schema::Result::User',
    'deleted_by',
    { join_type => 'left' }
);
__PACKAGE__->has_many(
    posts => 'GPForum::Schema::Result::Post',
    'thread_id'
);
__PACKAGE__->might_have(
    counters => 'GPForum::Schema::Result::ThreadCounter',
    'thread_id'
);
__PACKAGE__->has_many(
    counter_shards => 'GPForum::Schema::Result::ThreadCounterShard',
    'thread_id'
);

1;
