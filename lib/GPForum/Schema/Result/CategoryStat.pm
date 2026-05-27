package GPForum::Schema::Result::CategoryStat;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('category_stats');

__PACKAGE__->add_columns(
    category_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    thread_count => {
        data_type     => 'bigint',
        default_value => 0,
        is_nullable   => 0,
    },
    visible_thread_count => {
        data_type     => 'bigint',
        default_value => 0,
        is_nullable   => 0,
    },
    post_count => {
        data_type     => 'bigint',
        default_value => 0,
        is_nullable   => 0,
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

__PACKAGE__->set_primary_key('category_id');
__PACKAGE__->belongs_to(
    category => 'GPForum::Schema::Result::Category',
    'category_id'
);

1;
