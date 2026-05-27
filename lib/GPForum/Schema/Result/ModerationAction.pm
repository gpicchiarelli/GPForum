package GPForum::Schema::Result::ModerationAction;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('moderation_actions');

__PACKAGE__->add_columns(
    moderation_action_id => { data_type => 'uuid', is_nullable => 0 },
    actor_user_id        => { data_type => 'uuid', is_nullable => 0 },
    action_type          => { data_type => 'text', is_nullable => 0 },
    target_type          => { data_type => 'text', is_nullable => 0 },
    target_id            => { data_type => 'uuid', is_nullable => 0 },
    reason               => { data_type => 'text', is_nullable => 0 },
    metadata             =>
      { data_type => 'jsonb', is_nullable => 0, default_value => '{}' },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
    reversed_at =>
      { data_type => 'timestamp with time zone', is_nullable => 1 },
    reversed_by_user_id => { data_type => 'uuid', is_nullable => 1 },
);

__PACKAGE__->set_primary_key('moderation_action_id');
__PACKAGE__->belongs_to(
    actor => 'GPForum::Schema::Result::User',
    'actor_user_id'
);
__PACKAGE__->belongs_to(
    reversed_by => 'GPForum::Schema::Result::User',
    'reversed_by_user_id',
    { join_type => 'left' }
);

1;
