package GPForum::Schema::Result::NotificationInbox;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('notification_inbox');

__PACKAGE__->add_columns(
    recipient_user_id => { data_type => 'uuid', is_nullable => 0 },
    notification_id   => { data_type => 'uuid', is_nullable => 0 },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
    read_at    => { data_type => 'timestamp with time zone', is_nullable => 1 },
    rank_score => {
        data_type     => 'numeric',
        default_value => 0,
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key( 'recipient_user_id', 'notification_id' );
__PACKAGE__->belongs_to(
    recipient => 'GPForum::Schema::Result::User',
    'recipient_user_id'
);
__PACKAGE__->belongs_to(
    notification => 'GPForum::Schema::Result::Notification',
    {
        'foreign.notification_id' => 'self.notification_id',
        'foreign.created_at'      => 'self.created_at',
    }
);

1;
