package GPForum::Schema::Result::Post;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('posts');

__PACKAGE__->add_columns(
    post_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    thread_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    author_user_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    current_body_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    current_revision_id => {
        data_type   => 'uuid',
        is_nullable => 1,
    },
    position => {
        data_type   => 'bigint',
        is_nullable => 0,
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
    hidden_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
    locked_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
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

__PACKAGE__->set_primary_key('post_id');
__PACKAGE__->add_unique_constraint(
    posts_thread_position_key => [ 'thread_id', 'position' ] );
__PACKAGE__->belongs_to(
    thread => 'GPForum::Schema::Result::Thread',
    'thread_id'
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
    bodies => 'GPForum::Schema::Result::PostBody',
    'post_id'
);
__PACKAGE__->has_many(
    revisions => 'GPForum::Schema::Result::PostRevision',
    'post_id'
);
__PACKAGE__->belongs_to(
    current_body => 'GPForum::Schema::Result::PostBody',
    'current_body_id',
    { join_type => 'left' }
);
__PACKAGE__->belongs_to(
    current_revision => 'GPForum::Schema::Result::PostRevision',
    'current_revision_id',
    { join_type => 'left' }
);

1;
