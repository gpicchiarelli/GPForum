package GPForum::Schema::Result::Role;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('roles');

__PACKAGE__->add_columns(
    role_id     => { data_type => 'uuid', is_nullable => 0 },
    name        => { data_type => 'text', is_nullable => 0 },
    description =>
      { data_type => 'text', is_nullable => 0, default_value => q{} },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
);

__PACKAGE__->set_primary_key('role_id');
__PACKAGE__->add_unique_constraint( roles_name_key => ['name'] );
__PACKAGE__->has_many(
    role_permissions => 'GPForum::Schema::Result::RolePermission',
    'role_id'
);
__PACKAGE__->has_many(
    role_bindings => 'GPForum::Schema::Result::RoleBinding',
    'role_id'
);

1;
