package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Web::AdminAccess;
use Test::More;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT     => 50;
const my $REQUESTED_LIMIT   => 10;
const my $DASHBOARD_LIMIT   => 10;
const my $WRITE_RATE_LIMIT  => 20;
const my $WRITE_RATE_WINDOW => 60;

my $access = GPForum::Web::AdminAccess->new;

is( $access->page_limit(undef),
    $DEFAULT_LIMIT, 'page_limit defaults a missing size' );
is( $access->page_limit(0), $DEFAULT_LIMIT, 'page_limit defaults a zero size' );
is( $access->page_limit($REQUESTED_LIMIT),
    $REQUESTED_LIMIT, 'page_limit keeps an explicit size' );
is( $access->dashboard_limit,
    $DASHBOARD_LIMIT, 'dashboard_limit keeps the summary cap' );

is( $access->write_action, 'admin.write',
    'write_action is the staff write action' );
is_deeply(
    $access->write_rate_input(
        {
            action   => $access->write_action,
            actor_id => 'user-1',
        }
    ),
    {
        action         => 'admin.write',
        actor_id       => 'user-1',
        limit          => $WRITE_RATE_LIMIT,
        scope          => 'admin_http',
        window_seconds => $WRITE_RATE_WINDOW,
    },
    'write_rate_input uses the admin HTTP window'
);

is( $access->manage_action, 'manage', 'manage_action is the staff action' );
is( $access->view_action,   'view',   'view_action is the catalog action' );
is( $access->role_created_status,
    'role_created', 'role_created_status keeps the catalog write status' );
is( $access->permission_created_status,
    'permission_created',
    'permission_created_status keeps the permission write status' );
is( $access->role_permission_attached_status,
    'role_permission_attached',
    'role_permission_attached_status keeps the attach write status' );
is( $access->role_bound_status,
    'role_bound', 'role_bound_status keeps the binding write status' );
is( $access->role_binding_revoked_status,
    'role_binding_revoked',
    'role_binding_revoked_status keeps the revoke write status' );
is( $access->category_created_status,
    'category_created',
    'category_created_status keeps the category write status' );
is( $access->category_updated_status,
    'category_updated',
    'category_updated_status keeps the category update status' );
is( $access->default_redirect,
    'admin_roles', 'default_redirect keeps the roles catalog' );
is( $access->categories_redirect,
    'admin_categories', 'categories_redirect keeps the category catalog' );
is( $access->write_flash_key('role_created'),
    'admin.role_created', 'write_flash_key maps role create to the flash key' );
is( $access->write_flash_key('category_created'),
    'admin.category_created',
    'write_flash_key maps category create to the flash key' );
ok(
    !defined $access->write_flash_key('unknown'),
    'write_flash_key ignores an unmapped status'
);

is_deeply(
    $access->permission_target('manage'),
    {
        action        => 'manage',
        resource_type => 'admin_console',
    },
    'permission_target uses the admin_console resource'
);

ok(
    $access->is_failed( { status => 'failed' } ),
    'is_failed accepts a failed workflow'
);
ok(
    !$access->is_failed( { status => 'invalid' } ),
    'is_failed ignores mapped client errors'
);

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
    $access->invalid_request( { name => 'name is required' } ),
    {
        error  => 'The submitted admin request was invalid.',
        errors => { name => 'name is required' },
        title  => 'Invalid admin request',
    },
    'invalid_request keeps explicit field errors'
);

done_testing();

1;
