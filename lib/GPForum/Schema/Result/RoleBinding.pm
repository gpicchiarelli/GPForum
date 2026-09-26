# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::RoleBinding;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

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

# No unique constraint on the binding's scope. The database has one only among
# unrevoked bindings -- idx_role_bindings_active_unique, WHERE revoked_at IS
# NULL -- and DBIx::Class cannot express a partial one. Declared here, it
# would let find() treat the scope as a unique key and hand back a revoked
# binding. RoleBindingStore matches the index name in the database's error to
# recognise the conflict.
__PACKAGE__->belongs_to( user => 'GPForum::Schema::Result::User', 'user_id' );
__PACKAGE__->belongs_to( role => 'GPForum::Schema::Result::Role', 'role_id' );
__PACKAGE__->belongs_to(
    created_by => 'GPForum::Schema::Result::User',
    'created_by_user_id',
    { join_type => 'left' }
);

1;
