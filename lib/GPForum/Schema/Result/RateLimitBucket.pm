# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::RateLimitBucket;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('rate_limit_buckets');

__PACKAGE__->add_columns(
    scope => {
        data_type   => 'text',
        is_nullable => 0,
    },
    actor_hash => {
        data_type   => 'text',
        is_nullable => 0,
    },
    action => {
        data_type   => 'text',
        is_nullable => 0,
    },
    window_started_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    window_seconds => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    observed_count => {
        data_type     => 'integer',
        default_value => 0,
        is_nullable   => 0,
    },
    blocked_count => {
        data_type     => 'integer',
        default_value => 0,
        is_nullable   => 0,
    },
    first_seen_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    last_seen_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
    expires_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key(qw(scope actor_hash action window_started_at));

1;
