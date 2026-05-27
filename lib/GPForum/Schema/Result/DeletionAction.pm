package GPForum::Schema::Result::DeletionAction;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('deletion_actions');

__PACKAGE__->add_columns(
    deletion_action_id  => { data_type => 'uuid', is_nullable => 0 },
    deletion_request_id => { data_type => 'uuid', is_nullable => 0 },
    actor_id            => { data_type => 'uuid', is_nullable => 1 },
    action_type         => { data_type => 'text', is_nullable => 0 },
    metadata            =>
      { data_type => 'jsonb', is_nullable => 0, default_value => '{}' },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
);

__PACKAGE__->set_primary_key('deletion_action_id');
__PACKAGE__->belongs_to(
    deletion_request => 'GPForum::Schema::Result::DeletionRequest',
    'deletion_request_id'
);

1;
