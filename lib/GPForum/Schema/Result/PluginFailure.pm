# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::PluginFailure;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

use GPForum::Schema::JsonColumn;

our $VERSION = '0.001';

__PACKAGE__->table('plugin_failures');

__PACKAGE__->add_columns(
    plugin_failure_id => { data_type => 'uuid', is_nullable => 0 },
    plugin_id         => { data_type => 'uuid', is_nullable => 0 },
    hook_name         => { data_type => 'text', is_nullable => 1 },
    error_class       => { data_type => 'text', is_nullable => 0 },
    error_message     => { data_type => 'text', is_nullable => 0 },
    context           =>
      { data_type => 'jsonb', is_nullable => 0, default_value => '{}' },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
);

GPForum::Schema::JsonColumn->inflate_json_columns(__PACKAGE__);

__PACKAGE__->set_primary_key('plugin_failure_id');
__PACKAGE__->belongs_to(
    plugin => 'GPForum::Schema::Result::Plugin',
    'plugin_id'
);

1;
