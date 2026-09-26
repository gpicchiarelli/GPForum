# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Web::PrivacyAccess;
use Test::More;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT      => 25;
const my $REQUESTED_LIMIT    => 10;
const my $WRITE_RATE_LIMIT   => 20;
const my $REQUEST_RATE_LIMIT => 5;
const my $WRITE_RATE_WINDOW  => 60;

my $access = GPForum::Web::PrivacyAccess->new;

is( $access->page_limit(undef),
    $DEFAULT_LIMIT, 'page_limit defaults a missing size' );
is( $access->page_limit(0), $DEFAULT_LIMIT, 'page_limit defaults a zero size' );
is( $access->page_limit($REQUESTED_LIMIT),
    $REQUESTED_LIMIT, 'page_limit keeps an explicit size' );

is( $access->write_action, 'privacy.write',
    'write_action is the default write action' );
is( $access->request_action,
    'privacy.request', 'request_action is the member write action' );
is( $access->review_action,
    'privacy.review', 'review_action is the staff write action' );
is( $access->write_limit_for( $access->request_action ),
    $REQUEST_RATE_LIMIT, 'write_limit_for caps member requests' );
is( $access->write_limit_for( $access->review_action ),
    $WRITE_RATE_LIMIT, 'write_limit_for keeps staff review at 20' );
is_deeply(
    $access->write_rate_input(
        {
            action   => $access->request_action,
            actor_id => 'user-1',
        }
    ),
    {
        action         => 'privacy.request',
        actor_id       => 'user-1',
        limit          => $REQUEST_RATE_LIMIT,
        scope          => 'privacy_http',
        window_seconds => $WRITE_RATE_WINDOW,
    },
    'write_rate_input uses the member request window'
);
is_deeply(
    $access->write_rate_input(
        {
            action   => $access->review_action,
            actor_id => 'staff-1',
        }
    ),
    {
        action         => 'privacy.review',
        actor_id       => 'staff-1',
        limit          => $WRITE_RATE_LIMIT,
        scope          => 'privacy_http',
        window_seconds => $WRITE_RATE_WINDOW,
    },
    'write_rate_input uses the staff review window'
);

is( $access->manage_action, 'manage', 'manage_action is the staff action' );
is( $access->view_action,   'view',   'view_action is the review action' );
is( $access->deletion_approved_status,
    'deletion_approved',
    'deletion_approved_status keeps the approval write status' );
is( $access->deletion_held_status,
    'deletion_held', 'deletion_held_status keeps the hold write status' );
is( $access->default_redirect,
    'privacy_dashboard', 'default_redirect keeps the member dashboard' );
is(
    $access->write_flash_key('export_requested'),
    'privacy.export_requested',
    'write_flash_key maps export to the flash key'
);
is( $access->write_flash_key('deletion_approved'),
    'privacy.deletion_approved',
    'write_flash_key maps approval to the flash key' );
ok(
    !defined $access->write_flash_key('unknown'),
    'write_flash_key ignores an unmapped status'
);
is(
    $access->export_download_filename('export-own-1'),
    'gpforum-export-export-own-1.json',
    'export_download_filename uses the request id'
);
is( $access->export_download_filename('a"b'),
    'gpforum-export-a_b.json',
    'export_download_filename strips unsafe characters' );

is_deeply(
    $access->permission_target('manage'),
    {
        action        => 'manage',
        resource_type => 'privacy_rights',
    },
    'permission_target uses the privacy_rights resource'
);

ok(
    $access->is_failed( { status => 'failed' } ),
    'is_failed accepts a failed workflow'
);
ok( !$access->is_failed( { status => 'conflict' } ),
    'is_failed ignores a blocked hold' );

is( $access->failure_status( { status => 'not_found' } ),
    'not_found', 'failure_status keeps not_found' );
is( $access->failure_status( { status => 'invalid' } ),
    'invalid', 'failure_status keeps invalid' );
is( $access->failure_status( { status => 'conflict' } ),
    'conflict', 'failure_status keeps conflict' );
ok( !defined $access->failure_status( { status => 'failed' } ),
    'failure_status ignores system failures' );
ok( !defined $access->failure_status( { status => 'ok' } ),
    'failure_status ignores success' );

is_deeply(
    $access->invalid_request( { reason => 'reason is required' } ),
    {
        error  => 'The submitted privacy request was invalid.',
        errors => { reason => 'reason is required' },
        title  => 'Invalid privacy request',
    },
    'invalid_request keeps explicit field errors'
);
is_deeply(
    $access->conflict_payload('retention hold active'),
    {
        error  => 'retention hold active',
        status => 'blocked',
        title  => 'Privacy action blocked',
    },
    'conflict_payload keeps the blocked hold contract'
);

done_testing();

1;
