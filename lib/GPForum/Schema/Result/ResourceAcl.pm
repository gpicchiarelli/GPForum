package GPForum::Schema::Result::ResourceAcl;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('resource_acl');

__PACKAGE__->add_columns(
    acl_id        => { data_type => 'uuid', is_nullable => 0 },
    resource_type => { data_type => 'text', is_nullable => 0 },
    resource_id   => { data_type => 'uuid', is_nullable => 0 },
    user_id       => { data_type => 'uuid', is_nullable => 1 },
    role_id       => { data_type => 'uuid', is_nullable => 1 },
    permission_id => { data_type => 'uuid', is_nullable => 0 },
    owner_user_id => { data_type => 'uuid', is_nullable => 1 },
    space_id      => { data_type => 'uuid', is_nullable => 1 },
    visibility    =>
      { data_type => 'text', is_nullable => 0, default_value => 'public' },
    moderation_state =>
      { data_type => 'text', is_nullable => 0, default_value => 'visible' },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
    revoked_at => { data_type => 'timestamp with time zone', is_nullable => 1 },
);

__PACKAGE__->set_primary_key('acl_id');
__PACKAGE__->belongs_to(
    user => 'GPForum::Schema::Result::User',
    'user_id',
    { join_type => 'left' }
);
__PACKAGE__->belongs_to(
    role => 'GPForum::Schema::Result::Role',
    'role_id',
    { join_type => 'left' }
);
__PACKAGE__->belongs_to(
    permission => 'GPForum::Schema::Result::Permission',
    'permission_id'
);
__PACKAGE__->belongs_to(
    owner => 'GPForum::Schema::Result::User',
    'owner_user_id',
    { join_type => 'left' }
);

1;
