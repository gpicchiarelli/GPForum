package GPForum::Schema::Result::ThreadReadState;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('thread_read_state');

__PACKAGE__->add_columns(
    user_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    thread_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    last_read_position => {
        data_type   => 'bigint',
        is_nullable => 0,
    },
    last_read_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key( 'user_id', 'thread_id' );
__PACKAGE__->belongs_to( user => 'GPForum::Schema::Result::User', 'user_id' );
__PACKAGE__->belongs_to(
    thread => 'GPForum::Schema::Result::Thread',
    'thread_id'
);

1;
