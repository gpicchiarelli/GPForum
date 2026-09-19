package GPForum::Schema::Result::Suspension;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

use GPForum::Schema::JsonColumn;

our $VERSION = '0.001';

__PACKAGE__->table('suspensions');

__PACKAGE__->add_columns(
    suspension_id => { data_type => 'uuid', is_nullable => 0 },
    user_id       => { data_type => 'uuid', is_nullable => 0 },
    actor_user_id => { data_type => 'uuid', is_nullable => 0 },
    reason        => { data_type => 'text', is_nullable => 0 },
    valid_from => { data_type => 'timestamp with time zone', is_nullable => 0 },
    valid_to   => { data_type => 'timestamp with time zone', is_nullable => 1 },
    revoked_at => { data_type => 'timestamp with time zone', is_nullable => 1 },
    metadata   =>
      { data_type => 'jsonb', is_nullable => 0, default_value => '{}' },
);

GPForum::Schema::JsonColumn->inflate_json_columns(__PACKAGE__);

__PACKAGE__->set_primary_key('suspension_id');
__PACKAGE__->belongs_to( user => 'GPForum::Schema::Result::User', 'user_id' );
__PACKAGE__->belongs_to(
    actor => 'GPForum::Schema::Result::User',
    'actor_user_id'
);

1;
