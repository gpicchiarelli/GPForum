package GPForum::Schema::Result::Notification;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('notifications');

__PACKAGE__->add_columns(
    notification_id   => { data_type => 'uuid', is_nullable => 0 },
    recipient_user_id => { data_type => 'uuid', is_nullable => 0 },
    source_type       => { data_type => 'text', is_nullable => 0 },
    source_id         => { data_type => 'uuid', is_nullable => 1 },
    notification_type => { data_type => 'text', is_nullable => 0 },
    payload           => {
        data_type     => 'jsonb',
        default_value => '{}',
        is_nullable   => 0,
    },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
);

__PACKAGE__->set_primary_key( 'notification_id', 'created_at' );
__PACKAGE__->belongs_to(
    recipient => 'GPForum::Schema::Result::User',
    'recipient_user_id'
);

1;
