# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::Mention;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('mentions');

__PACKAGE__->add_columns(
    mention_id         => { data_type => 'uuid', is_nullable => 0 },
    source_type        => { data_type => 'text', is_nullable => 0 },
    source_id          => { data_type => 'uuid', is_nullable => 0 },
    actor_id           => { data_type => 'uuid', is_nullable => 0 },
    mentioned_user_id  => { data_type => 'uuid', is_nullable => 0 },
    mentioned_username => { data_type => 'text', is_nullable => 0 },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
);

__PACKAGE__->set_primary_key('mention_id');
__PACKAGE__->add_unique_constraint( mentions_source_user_key =>
      [ 'source_type', 'source_id', 'mentioned_user_id' ] );
__PACKAGE__->belongs_to(
    actor => 'GPForum::Schema::Result::User',
    'actor_id'
);
__PACKAGE__->belongs_to(
    mentioned_user => 'GPForum::Schema::Result::User',
    'mentioned_user_id'
);

1;
