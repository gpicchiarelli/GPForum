package GPForum::Schema::Result::Permission;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('permissions');

__PACKAGE__->add_columns(
    permission_id => { data_type => 'uuid', is_nullable => 0 },
    name          => { data_type => 'text', is_nullable => 0 },
    resource_type => { data_type => 'text', is_nullable => 0 },
    action        => { data_type => 'text', is_nullable => 0 },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
);

__PACKAGE__->set_primary_key('permission_id');
__PACKAGE__->add_unique_constraint( permissions_name_key => ['name'] );
__PACKAGE__->add_unique_constraint(
    permissions_resource_action_key => [ 'resource_type', 'action' ] );
__PACKAGE__->has_many(
    role_permissions => 'GPForum::Schema::Result::RolePermission',
    'permission_id'
);

1;
