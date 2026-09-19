package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Web::PrivacyAccess;
use Test::More;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT   => 25;
const my $REQUESTED_LIMIT => 10;

my $access = GPForum::Web::PrivacyAccess->new;

is( $access->page_limit(undef),
    $DEFAULT_LIMIT, 'page_limit defaults a missing size' );
is( $access->page_limit(0), $DEFAULT_LIMIT, 'page_limit defaults a zero size' );
is( $access->page_limit($REQUESTED_LIMIT),
    $REQUESTED_LIMIT, 'page_limit keeps an explicit size' );

is( $access->manage_action, 'manage', 'manage_action is the staff action' );
is( $access->view_action,   'view',   'view_action is the review action' );
is( $access->deletion_approved_status,
    'deletion_approved',
    'deletion_approved_status keeps the approval write status' );
is( $access->deletion_held_status,
    'deletion_held', 'deletion_held_status keeps the hold write status' );
is( $access->default_redirect,
    'privacy_dashboard', 'default_redirect keeps the member dashboard' );

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
