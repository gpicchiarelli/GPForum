package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use Const::Fast;
use GPForum::Web::ModerationAccess;
use Test::More;

our $VERSION = '0.001';

const my $DEFAULT_QUEUE_LIMIT => 50;
const my $REQUESTED_LIMIT     => 10;
const my $WRITE_RATE_LIMIT    => 20;
const my $WRITE_RATE_WINDOW   => 60;

my $access = GPForum::Web::ModerationAccess->new;

is( $access->write_action,
    'moderation.write', 'write_action is the staff write action' );
is_deeply(
    $access->write_rate_input(
        {
            action   => $access->write_action,
            actor_id => 'user-1',
        }
    ),
    {
        action         => 'moderation.write',
        actor_id       => 'user-1',
        limit          => $WRITE_RATE_LIMIT,
        scope          => 'moderation_http',
        window_seconds => $WRITE_RATE_WINDOW,
    },
    'write_rate_input uses the moderation HTTP window'
);

is( $access->queue_limit(undef),
    $DEFAULT_QUEUE_LIMIT, 'queue_limit defaults a missing size' );
is( $access->queue_limit(0),
    $DEFAULT_QUEUE_LIMIT, 'queue_limit defaults a zero size' );
is( $access->queue_limit($REQUESTED_LIMIT),
    $REQUESTED_LIMIT, 'queue_limit keeps an explicit size' );

is( $access->queue_status(undef),
    'open', 'queue_status defaults a missing filter' );
is( $access->queue_status(q{}),
    'open', 'queue_status defaults an empty filter' );
is( $access->queue_status('assigned'),
    'assigned', 'queue_status keeps an explicit filter' );

is( $access->suspension_status(undef),
    'active', 'suspension_status defaults a missing filter' );
is( $access->suspension_status('expired'),
    'active', 'suspension_status defaults a non-all filter' );
is( $access->suspension_status('all'),
    'all', 'suspension_status keeps the all filter' );

is_deeply(
    $access->authorization_target('assign'),
    {
        action        => 'assign',
        resource_type => 'report',
    },
    'authorization_target defaults a report resource'
);
is_deeply(
    $access->authorization_target( 'post', 'hide' ),
    {
        action        => 'hide',
        resource_type => 'post',
    },
    'authorization_target keeps an explicit resource'
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
    $access->invalid_request( { reason => 'reason is required' } ),
    {
        error  => 'The submitted moderation request was invalid.',
        errors => { reason => 'reason is required' },
        title  => 'Invalid moderation request',
    },
    'invalid_request keeps explicit field errors'
);

is( $access->view_action, 'view', 'view_action is the review action' );
is( $access->view_queue_action,
    'view_queue', 'view_queue_action is the queue action' );
is( $access->moderate_action, 'moderate',
    'moderate_action is the content action' );
is( $access->reverse_action, 'reverse',
    'reverse_action is the reversal action' );
is( $access->assign_action, 'assign',
    'assign_action is the queue write action' );
is( $access->resolve_action, 'resolve',
    'resolve_action is the resolution action' );
is( $access->suspend_action, 'suspend', 'suspend_action is the user action' );
is( $access->moderation_resource,
    'moderation_action',
    'moderation_resource keeps the action history resource' );
is( $access->suspension_resource,
    'suspension', 'suspension_resource keeps the suspension resource' );
is( $access->post_resource, 'post', 'post_resource keeps the post resource' );
is( $access->thread_resource, 'thread',
    'thread_resource keeps the thread resource' );
is( $access->user_resource, 'user', 'user_resource keeps the user resource' );
is( $access->post_hidden_status,
    'post_hidden', 'post_hidden_status keeps the hide write status' );
is( $access->post_restored_status,
    'post_restored', 'post_restored_status keeps the restore write status' );
is( $access->thread_locked_status,
    'thread_locked', 'thread_locked_status keeps the lock write status' );
is( $access->thread_unlocked_status,
    'thread_unlocked', 'thread_unlocked_status keeps the unlock write status' );
is( $access->thread_hidden_status,
    'thread_hidden', 'thread_hidden_status keeps the hide write status' );
is( $access->thread_restored_status,
    'thread_restored',
    'thread_restored_status keeps the restore write status' );
is( $access->action_reversed_status,
    'action_reversed',
    'action_reversed_status keeps the reversal write status' );
is( $access->assigned_status,
    'assigned', 'assigned_status keeps the assign write status' );
is( $access->released_status,
    'released', 'released_status keeps the release write status' );
is( $access->resolved_status,
    'resolved', 'resolved_status keeps the resolve write status' );
is( $access->user_suspended_status,
    'user_suspended', 'user_suspended_status keeps the suspend write status' );
is( $access->suspension_revoked_status,
    'suspension_revoked',
    'suspension_revoked_status keeps the revoke write status' );
is(
    $access->write_flash_key('post_hidden'),
    'moderation.action.post_hidden',
    'write_flash_key maps hide to the action catalog key'
);
is( $access->write_flash_key('assigned'),
    'moderation.assigned', 'write_flash_key maps assign to the flash key' );
ok(
    !defined $access->write_flash_key('unknown'),
    'write_flash_key ignores an unmapped status'
);

done_testing();

1;
