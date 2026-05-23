package GPForum::Schema::Result::Bookmark;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('bookmarks');

__PACKAGE__->add_columns(
    bookmark_id => { data_type => 'uuid', is_nullable => 0 },
    user_id     => { data_type => 'uuid', is_nullable => 0 },
    target_type => { data_type => 'text', is_nullable => 0 },
    target_id   => { data_type => 'uuid', is_nullable => 0 },
    note => { data_type => 'text', is_nullable => 0, default_value => q{} },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
    deleted_at => { data_type => 'timestamp with time zone', is_nullable => 1 },
);

__PACKAGE__->set_primary_key('bookmark_id');
__PACKAGE__->add_unique_constraint(
    bookmarks_user_target_key => [ 'user_id', 'target_type', 'target_id' ] );
__PACKAGE__->belongs_to( user => 'GPForum::Schema::Result::User', 'user_id' );

1;
