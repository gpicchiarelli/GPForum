package GPForum::Schema::Result::Notification;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

use GPForum::Schema::JsonColumn;

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

GPForum::Schema::JsonColumn->inflate_json_columns(__PACKAGE__);

__PACKAGE__->set_primary_key( 'notification_id', 'created_at' );
__PACKAGE__->belongs_to(
    recipient => 'GPForum::Schema::Result::User',
    'recipient_user_id'
);
__PACKAGE__->has_many(
    inbox_entries => 'GPForum::Schema::Result::NotificationInbox',
    {
        'foreign.notification_id' => 'self.notification_id',
        'foreign.created_at'      => 'self.created_at',
    }
);

1;
