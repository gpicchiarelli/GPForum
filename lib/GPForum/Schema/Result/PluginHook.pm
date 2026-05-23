package GPForum::Schema::Result::PluginHook;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

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
__PACKAGE__->belongs_to(
    plugin => 'GPForum::Schema::Result::Plugin',
    'plugin_id'
);

1;
