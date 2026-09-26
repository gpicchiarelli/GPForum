# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::EndpointQueryBudget;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('endpoint_query_budgets');

__PACKAGE__->add_columns(
    endpoint_name => {
        data_type   => 'text',
        is_nullable => 0,
    },
    max_queries => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    max_transactions => {
        data_type     => 'integer',
        default_value => 1,
        is_nullable   => 0,
    },
    notes => {
        data_type     => 'text',
        default_value => q{},
        is_nullable   => 0,
    },
    created_at => {
        data_type   => 'timestamp with time zone',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('endpoint_name');

1;
