# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::NotificationPreference;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('notification_preferences');

__PACKAGE__->add_columns(
    user_id => { data_type => 'uuid', is_nullable => 0 },
    channel => { data_type => 'text', is_nullable => 0 },
    enabled => {
        data_type     => 'boolean',
        default_value => 1,
        is_nullable   => 0,
    },
    digest_frequency => {
        data_type     => 'text',
        default_value => 'daily',
        is_nullable   => 0,
    },
    updated_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
);

__PACKAGE__->set_primary_key( 'user_id', 'channel' );
__PACKAGE__->belongs_to( user => 'GPForum::Schema::Result::User', 'user_id' );

1;
