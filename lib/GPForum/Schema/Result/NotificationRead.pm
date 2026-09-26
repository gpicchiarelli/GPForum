# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::NotificationRead;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('notification_reads');

__PACKAGE__->add_columns(
    notification_id   => { data_type => 'uuid', is_nullable => 0 },
    recipient_user_id => { data_type => 'uuid', is_nullable => 0 },
    read_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
);

__PACKAGE__->set_primary_key( 'notification_id', 'recipient_user_id' );
__PACKAGE__->belongs_to(
    recipient => 'GPForum::Schema::Result::User',
    'recipient_user_id'
);

1;
