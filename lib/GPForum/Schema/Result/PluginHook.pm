# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::PluginHook;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('plugin_hooks');

__PACKAGE__->add_columns(
    hook_id            => { data_type => 'uuid',    is_nullable => 0 },
    plugin_id          => { data_type => 'uuid',    is_nullable => 0 },
    hook_name          => { data_type => 'text',    is_nullable => 0 },
    callback_name      => { data_type => 'text',    is_nullable => 0 },
    execution_order    => { data_type => 'integer', is_nullable => 0 },
    timeout_ms         => { data_type => 'integer', is_nullable => 0 },
    side_effect_policy => { data_type => 'text',    is_nullable => 0 },
    enabled            => { data_type => 'boolean', is_nullable => 0 },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
);

__PACKAGE__->set_primary_key('hook_id');
__PACKAGE__->add_unique_constraint(
    idx_plugin_hooks_plugin_name_unique => [qw(plugin_id hook_name)] );
__PACKAGE__->belongs_to(
    plugin => 'GPForum::Schema::Result::Plugin',
    'plugin_id'
);

1;
