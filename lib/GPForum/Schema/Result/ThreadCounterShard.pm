package GPForum::Schema::Result::ThreadCounterShard;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('thread_counter_shards');

__PACKAGE__->add_columns(
    thread_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    shard_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    reply_count_delta => {
        data_type     => 'bigint',
        default_value => 0,
        is_nullable   => 0,
    },
    last_updated_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key( 'thread_id', 'shard_id' );
__PACKAGE__->belongs_to(
    thread => 'GPForum::Schema::Result::Thread',
    'thread_id'
);

1;
