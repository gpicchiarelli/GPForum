# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::ModerationAction;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

use GPForum::Schema::JsonColumn;

our $VERSION = '0.001';

__PACKAGE__->table('moderation_actions');

__PACKAGE__->add_columns(
    moderation_action_id => { data_type => 'uuid', is_nullable => 0 },
    actor_user_id        => { data_type => 'uuid', is_nullable => 0 },
    action_type          => { data_type => 'text', is_nullable => 0 },
    command_id           => { data_type => 'uuid', is_nullable => 1 },
    target_type          => { data_type => 'text', is_nullable => 0 },
    target_id            => { data_type => 'uuid', is_nullable => 0 },
    reason               => { data_type => 'text', is_nullable => 0 },
    metadata             =>
      { data_type => 'jsonb', is_nullable => 0, default_value => '{}' },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
    reversed_at =>
      { data_type => 'timestamp with time zone', is_nullable => 1 },
    reversed_by_user_id => { data_type => 'uuid', is_nullable => 1 },
);

GPForum::Schema::JsonColumn->inflate_json_columns(__PACKAGE__);

__PACKAGE__->set_primary_key('moderation_action_id');

# The database's own name, so the key and the index are recognisably one
# thing. The index is partial on command_id IS NOT NULL, which changes nothing
# for a lookup by a command id: NULL never equals anything.
__PACKAGE__->add_unique_constraint(
    idx_moderation_actions_command_id => ['command_id'] );
__PACKAGE__->belongs_to(
    actor => 'GPForum::Schema::Result::User',
    'actor_user_id'
);
__PACKAGE__->belongs_to(
    reversed_by => 'GPForum::Schema::Result::User',
    'reversed_by_user_id',
    { join_type => 'left' }
);

1;
