package GPForum::Schema::Result::Plugin;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core';

use GPForum::Schema::JsonColumn;

our $VERSION = '0.001';

__PACKAGE__->table('plugins');

__PACKAGE__->add_columns(
    plugin_id                => { data_type => 'uuid', is_nullable => 0 },
    name                     => { data_type => 'text', is_nullable => 0 },
    version                  => { data_type => 'text', is_nullable => 0 },
    author                   => { data_type => 'text', is_nullable => 0 },
    compatible_gpforum_range => { data_type => 'text', is_nullable => 0 },
    status                   => { data_type => 'text', is_nullable => 0 },
    capabilities             =>
      { data_type => 'jsonb', is_nullable => 0, default_value => '[]' },
    required_permissions =>
      { data_type => 'jsonb', is_nullable => 0, default_value => '[]' },
    config_schema =>
      { data_type => 'jsonb', is_nullable => 0, default_value => '{}' },
    installed_at =>
      { data_type => 'timestamp with time zone', is_nullable => 0 },
    enabled_at => { data_type => 'timestamp with time zone', is_nullable => 1 },
    disabled_at =>
      { data_type => 'timestamp with time zone', is_nullable => 1 },
);

GPForum::Schema::JsonColumn->inflate_json_columns(__PACKAGE__);

__PACKAGE__->set_primary_key('plugin_id');
__PACKAGE__->add_unique_constraint(
    plugins_name_version_key => [ 'name', 'version' ] );
__PACKAGE__->has_many(
    hooks => 'GPForum::Schema::Result::PluginHook',
    'plugin_id'
);
__PACKAGE__->has_many(
    failures => 'GPForum::Schema::Result::PluginFailure',
    'plugin_id'
);

1;
