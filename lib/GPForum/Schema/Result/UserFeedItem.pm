package GPForum::Schema::Result::UserFeedItem;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('user_feed_items');

__PACKAGE__->add_columns(
    user_id    => { data_type => 'uuid',                     is_nullable => 0 },
    item_type  => { data_type => 'text',                     is_nullable => 0 },
    item_id    => { data_type => 'uuid',                     is_nullable => 0 },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
    rank_score =>
      { data_type => 'numeric', is_nullable => 0, default_value => 0 },
    visibility_version => { data_type => 'bigint', is_nullable => 0 },
    permission_version => { data_type => 'bigint', is_nullable => 0 },
);

__PACKAGE__->set_primary_key( 'user_id', 'item_type', 'item_id' );
__PACKAGE__->belongs_to( user => 'GPForum::Schema::Result::User', 'user_id' );

1;
