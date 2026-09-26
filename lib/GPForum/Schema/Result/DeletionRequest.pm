# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::DeletionRequest;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('deletion_requests');

__PACKAGE__->add_columns(
    deletion_request_id => { data_type => 'uuid', is_nullable => 0 },
    requester_user_id   => { data_type => 'uuid', is_nullable => 1 },
    resource_type       => { data_type => 'text', is_nullable => 0 },
    resource_id         => { data_type => 'uuid', is_nullable => 0 },
    request_type        => { data_type => 'text', is_nullable => 0 },
    reason              => { data_type => 'text', is_nullable => 0 },
    status              => { data_type => 'text', is_nullable => 0 },
    created_at => { data_type => 'timestamp with time zone', is_nullable => 0 },
    completed_at =>
      { data_type => 'timestamp with time zone', is_nullable => 1 },
);

__PACKAGE__->set_primary_key('deletion_request_id');
__PACKAGE__->belongs_to(
    requester => 'GPForum::Schema::Result::User',
    'requester_user_id',
    { join_type => 'left' }
);
__PACKAGE__->has_many(
    actions => 'GPForum::Schema::Result::DeletionAction',
    'deletion_request_id'
);
__PACKAGE__->has_many(
    erasure_jobs => 'GPForum::Schema::Result::ErasureJob',
    'deletion_request_id'
);

1;
