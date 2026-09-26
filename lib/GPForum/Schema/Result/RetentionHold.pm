# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::RetentionHold;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('retention_holds');

__PACKAGE__->add_columns(
    retention_hold_id => { data_type => 'uuid', is_nullable => 0 },
    resource_type     => { data_type => 'text', is_nullable => 0 },
    resource_id       => { data_type => 'uuid', is_nullable => 0 },
    reason            => { data_type => 'text', is_nullable => 0 },
    starts_at  => { data_type => 'timestamp with time zone', is_nullable => 0 },
    ends_at    => { data_type => 'timestamp with time zone', is_nullable => 1 },
    created_by => { data_type => 'uuid',                     is_nullable => 1 },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
);

__PACKAGE__->set_primary_key('retention_hold_id');

1;
