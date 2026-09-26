# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::EventIdempotencyKey;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('event_idempotency_keys');

__PACKAGE__->add_columns(
    idempotency_key => {
        data_type   => 'text',
        is_nullable => 0,
    },
    event_id => {
        data_type   => 'uuid',
        is_nullable => 0,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },

    # NULL means the row is a claim that no worker has finished yet. The
    # single created_at could not distinguish "someone is running this" from
    # "this has been handled", so nothing could be excluded on that basis.
    completed_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('idempotency_key');

1;
