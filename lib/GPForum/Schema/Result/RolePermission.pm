# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::RolePermission;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('role_permissions');

__PACKAGE__->add_columns(
    role_id       => { data_type => 'uuid', is_nullable => 0 },
    permission_id => { data_type => 'uuid', is_nullable => 0 },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
);

__PACKAGE__->set_primary_key( 'role_id', 'permission_id' );
__PACKAGE__->belongs_to( role => 'GPForum::Schema::Result::Role', 'role_id' );
__PACKAGE__->belongs_to(
    permission => 'GPForum::Schema::Result::Permission',
    'permission_id'
);

1;
