package GPForum::Schema::Result::RoleBinding;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

our $VERSION = '0.001';

__PACKAGE__->table('role_bindings');

__PACKAGE__->add_columns(
    binding_id         => { data_type => 'uuid', is_nullable => 0 },
    user_id            => { data_type => 'uuid', is_nullable => 0 },
    role_id            => { data_type => 'uuid', is_nullable => 0 },
    resource_type      => { data_type => 'text', is_nullable => 0 },
    resource_id        => { data_type => 'uuid', is_nullable => 1 },
    space_id           => { data_type => 'uuid', is_nullable => 1 },
    created_by_user_id => { data_type => 'uuid', is_nullable => 1 },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
    revoked_at => { data_type => 'timestamp with time zone', is_nullable => 1 },
);

__PACKAGE__->set_primary_key('binding_id');
__PACKAGE__->add_unique_constraint( idx_role_bindings_active_unique =>
      [qw(user_id role_id resource_type resource_id space_id)] );
__PACKAGE__->belongs_to( user => 'GPForum::Schema::Result::User', 'user_id' );
__PACKAGE__->belongs_to( role => 'GPForum::Schema::Result::Role', 'role_id' );
__PACKAGE__->belongs_to(
    created_by => 'GPForum::Schema::Result::User',
    'created_by_user_id',
    { join_type => 'left' }
);

1;
