# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Privacy::Erasure;
use GPForum::Service::Privacy::Record;
use Test::More;

our $VERSION = '0.001';

my $records = GPForum::Service::Privacy::Record->new;
my $request = {
    deletion_request_id => 'del-1',
    request_type        => 'anonymize',
    resource_id         => 'user-1',
    resource_type       => 'user',
    status              => 'pending',
};
is_deeply( $records->request_payload($request),
    $request, 'record payload keeps canonical deletion-request fields' );
ok( $records->has_text('del-1'), 'record treats identifiers as text' );
ok( !$records->has_text(q{}),    'record rejects empty strings' );

my $job = $records->job_hash(
    {
        completed_at        => undef,
        deletion_request_id => 'del-1',
        erasure_job_id      => 'job-1',
        last_error          => undef,
        scheduled_at        => '2026-09-19T12:00:00Z',
        status              => 'pending',
    }
);
is( $job->{erasure_job_id}, 'job-1', 'record copies erasure-job identifiers' );
ok( !$records->job_hash(undef), 'record returns undef for a missing job' );

my $erasure = GPForum::Service::Privacy::Erasure->new;
ok(
    $erasure->is_user_resource($request),
    'erasure treats user aggregates as erasable'
);
ok( !$erasure->is_user_resource( { resource_type => 'post' } ),
    'erasure skips non-user resources' );
is( $erasure->skip_reason( { resource_type => 'post' }, undef ),
    'resource_not_user', 'erasure names a non-user skip reason' );
is( $erasure->skip_reason( $request, undef ),
    'user_not_found', 'erasure names a missing-user skip reason' );
ok( $erasure->already_deleted( { deleted_at => '2026-09-19T12:00:00Z' } ),
    'erasure detects an already deleted user' );
ok( !$erasure->already_deleted( { deleted_at => undef } ),
    'erasure detects an active user' );
is( $erasure->safe_identifier('User-1'),
    'user1', 'erasure keeps a lowercase alphanumeric identifier' );
is( $erasure->anonymous_username('user-1'),
    'deleted-user1', 'erasure builds the deleted username' );
is(
    $erasure->anonymous_email('user-1'),
    'deleted+user1@example.invalid',
    'erasure builds the deleted invalid-mail address'
);

my $values = $erasure->user_values( 'user-1', '2026-09-19T12:00:00Z' );
is( $values->{status}, 'deleted', 'erasure marks the user deleted' );
is(
    $values->{display_name},
    'Deleted member',
    'erasure replaces the public display name'
);
is_deeply(
    $erasure->result( 'user-1', 1 ),
    { idempotent => 1, user_id => 'user-1' },
    'erasure result marks an idempotent replay'
);

done_testing();

1;
