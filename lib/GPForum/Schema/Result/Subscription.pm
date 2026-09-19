package GPForum::Schema::Result::Subscription;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('subscriptions');

__PACKAGE__->add_columns(
    subscription_id => { data_type => 'uuid', is_nullable => 0 },
    user_id         => { data_type => 'uuid', is_nullable => 0 },
    target_type     => { data_type => 'text', is_nullable => 0 },
    target_id       => { data_type => 'uuid', is_nullable => 0 },
    preference      => {
        data_type     => 'text',
        default_value => 'all',
        is_nullable   => 0,
    },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
    muted_at   => { data_type => 'timestamp with time zone', is_nullable => 1 },
    revoked_at => { data_type => 'timestamp with time zone', is_nullable => 1 },
);

__PACKAGE__->set_primary_key('subscription_id');
__PACKAGE__->add_unique_constraint(
    subscriptions_unique_target => [ 'user_id', 'target_type', 'target_id' ] );
__PACKAGE__->belongs_to( user => 'GPForum::Schema::Result::User', 'user_id' );

1;
