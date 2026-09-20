package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Admin::AuditReview;
use GPForum::Service::Moderation::ActionStore;
use GPForum::Service::Moderation::ReportStore;
use GPForum::Service::Moderation::ReviewReader;
use GPForum::Service::Moderation::SuspensionStore;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;

our $VERSION = '0.001';

const my $QUEUE_LIMIT         => 25;
const my $AUDIT_LIMIT         => 10;
const my $CREATED_REPORTS     => 1;
const my $CREATED_EVENTS      => 4;
const my $CREATED_OUTBOX_ROWS => 4;
const my $MODERATION_EVENTS   => 8;
const my $MODERATION_OUTBOX   => 8;
const my $FIRST_EVENT_COUNT   => 1;
const my $SECOND_EVENT_COUNT  => 2;
const my $CREATED_ACTIONS     => 3;
const my $ACTION_AUDIT_ROWS   => 7;
const my $CREATED_AUDIT_ROWS  => 8;
const my $FIRST_ACTION_INDEX  => 0;
const my $SECOND_ACTION_INDEX => 1;
const my $THIRD_ACTION_INDEX  => 2;
const my $ACTION_FETCH_ROWS   => 3;
const my $FIRST_AUDIT_INDEX   => 0;
const my $SECOND_AUDIT_INDEX  => 1;

my $reports            = GPForum::Test::ModerationResultSet->new;
my $moderation_actions = GPForum::Test::ModerationResultSet->new;
my $posts              = GPForum::Test::ModerationResultSet->new;
my $threads            = GPForum::Test::ModerationResultSet->new;
my $users              = GPForum::Test::ModerationResultSet->new;
my $suspensions        = GPForum::Test::ModerationResultSet->new;
my $audit_log          = GPForum::Test::ModerationResultSet->new;
my $event_log          = GPForum::Test::ModerationResultSet->new;
my $outbox_messages    = GPForum::Test::ModerationResultSet->new;
my $schema             = GPForum::Test::ModerationSchema->new(
    resultsets => {
        Report           => $reports,
        ModerationAction => $moderation_actions,
        Post             => $posts,
        Suspension       => $suspensions,
        Thread           => $threads,
        User             => $users,
        AuditLog         => $audit_log,
        EventLog         => $event_log,
        OutboxMessage    => $outbox_messages,
    },
);
my $clock = GPForum::Test::FixedClock->new;

$posts->create(
    {
        post_id          => 'post-1',
        moderation_state => 'visible',
        hidden_at        => undef,
    }
);
$threads->create(
    {
        thread_id        => 'thread-1',
        moderation_state => 'visible',
        locked_at        => undef,
        hidden_at        => undef,
    }
);
$users->create(
    {
        id         => 'user-2',
        status     => 'active',
        updated_at => '2026-05-23T11:00:00Z',
    }
);

my $report_store = GPForum::Service::Moderation::ReportStore->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);
my $report = $report_store->create_report(
    {
        reporter_user_id => 'user-1',
        target_type      => 'post',
        target_id        => 'post-1',
        reason           => 'spam',
        details          => 'link ripetuti',
    }
);

is( $report->{report_id},        'generated-1', 'report id is generated' );
is( $report->{reporter_user_id}, 'user-1',      'report stores reporter' );
is( $report->{target_type},      'post',        'report stores target type' );
is( $report->{target_id},        'post-1',      'report stores target id' );
is( $report->{reason},           'spam',        'report stores reason' );
is( $report->{status},           'open',        'report starts open' );
is( $report->{created_at},
    '2026-05-23T12:00:00Z', 'report stores creation time' );
is( scalar @{ $reports->created }, $CREATED_REPORTS, 'report row is inserted' );
is( scalar @{ $event_log->created },
    $FIRST_EVENT_COUNT, 'report creation records a domain event' );
is( $event_log->created->[$FIRST_AUDIT_INDEX]{event_type},
    'report.created', 'report event type is explicit' );
is( scalar @{ $outbox_messages->created },
    $FIRST_EVENT_COUNT, 'report creation records outbox handoff' );
is( $outbox_messages->created->[$FIRST_AUDIT_INDEX]{event_id},
    'generated-3', 'report outbox points to report event' );
is( $audit_log->created->[$FIRST_AUDIT_INDEX]{action},
    'report.created', 'report creation records audit row' );
is( $audit_log->created->[$FIRST_AUDIT_INDEX]{metadata}{report_id},
    'generated-1', 'report audit stores report id' );

my $assigned = $report_store->assign_report( 'generated-1', 'moderator-1' );
is( $assigned->{report_id}, 'generated-1', 'assignment returns report id' );
is( $assigned->{assigned_moderator_user_id},
    'moderator-1', 'assignment stores moderator' );
is( $reports->find('generated-1')->get_column('assigned_moderator_user_id'),
    'moderator-1', 'report row receives assigned moderator' );
is( scalar @{ $event_log->created },
    $SECOND_EVENT_COUNT, 'report assignment records a domain event' );
is( $event_log->created->[$SECOND_AUDIT_INDEX]{event_type},
    'report.assigned', 'assignment event type is explicit' );
is( $audit_log->created->[$SECOND_AUDIT_INDEX]{action},
    'report.assigned', 'assignment records audit row' );

my $assignment_events = scalar @{ $event_log->created };
my $same_assignment =
  $report_store->assign_report( 'generated-1', 'moderator-1' );
is( $same_assignment->{assigned_moderator_user_id},
    'moderator-1', 'same assignment is idempotent' );
is( scalar @{ $event_log->created },
    $assignment_events, 'same assignment does not emit duplicate event' );

my $queue = $report_store->list_queue( { limit => $QUEUE_LIMIT } );
is( scalar @{$queue}, $CREATED_REPORTS,     'moderation queue can be listed' );
is( $reports->last_query->{status}, 'open', 'queue filters open reports' );
is( $reports->last_attrs->{rows},   $QUEUE_LIMIT, 'queue applies limit' );

my $released = $report_store->release_report( 'generated-1', 'moderator-1' );
is( $released->{report_id}, 'generated-1', 'release returns report id' );
is( $released->{assigned_moderator_user_id},
    undef, 'release clears moderator assignment' );
is( $reports->find('generated-1')->get_column('assigned_moderator_user_id'),
    undef, 'report row clears assigned moderator' );
is( $event_log->created->[-1]{event_type},
    'report.released', 'release event type is explicit' );
is( $audit_log->created->[-1]{action},
    'report.released', 'release records audit row' );
my $release_events = scalar @{ $event_log->created };
my $same_release =
  $report_store->release_report( 'generated-1', 'moderator-1' );
is( $same_release->{assigned_moderator_user_id},
    undef, 'same release is idempotent' );
is( scalar @{ $event_log->created },
    $release_events, 'same release does not emit duplicate event' );

my $resolved = $report_store->resolve_report( 'generated-1', 'hidden_post' );
is( $resolved->{status},     'resolved',    'report can be resolved' );
is( $resolved->{resolution}, 'hidden_post', 'resolution reason is stored' );
is( $resolved->{resolved_at},
    '2026-05-23T12:00:00Z', 'resolution stores timestamp' );
is( $reports->find('generated-1')->get_column('status'),
    'resolved', 'report row is updated as resolved' );
is( scalar @{ $event_log->created },
    $CREATED_EVENTS, 'report resolution records a domain event' );
is( scalar @{ $outbox_messages->created },
    $CREATED_OUTBOX_ROWS, 'report transitions record outbox handoffs' );
is( $audit_log->created->[-1]{action},
    'report.resolved', 'resolution records audit row' );

my $action_store = GPForum::Service::Moderation::ActionStore->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);
my $hidden = $action_store->hide_post(
    {
        actor_user_id => 'moderator-1',
        post_id       => 'post-1',
        reason        => 'spam',
    }
);

ok( $hidden->{ok}, 'post hide action succeeds' );
is( $hidden->{action}{moderation_action_id},
    'generated-1', 'hide action id is generated' );
is( $hidden->{action}{action_type}, 'post.hidden', 'hide action type stored' );
is( $hidden->{action}{target_type}, 'post',        'hide target type stored' );
is( $hidden->{action}{target_id},   'post-1',      'hide target id stored' );
is( $posts->find('post-1')->get_column('moderation_state'),
    'hidden', 'post is hidden' );
is( $posts->find('post-1')->get_column('hidden_at'),
    '2026-05-23T12:00:00Z', 'post hidden timestamp is stored' );

my $restored = $action_store->restore_post(
    {
        actor_user_id => 'moderator-1',
        post_id       => 'post-1',
        reason        => 'appeal accepted',
    }
);
ok( $restored->{ok}, 'post restore action succeeds' );
is( $restored->{action}{action_type},
    'post.restored', 'restore action type stored' );
is( $posts->find('post-1')->get_column('moderation_state'),
    'visible', 'post is restored' );
is( $posts->find('post-1')->get_column('hidden_at'),
    undef, 'post hidden timestamp is cleared' );

my $locked = $action_store->lock_thread(
    {
        actor_user_id => 'moderator-1',
        thread_id     => 'thread-1',
        reason        => 'heated discussion',
    }
);
ok( $locked->{ok}, 'thread lock action succeeds' );
is( $locked->{action}{action_type},
    'thread.locked', 'lock action type stored' );
is( $threads->find('thread-1')->get_column('moderation_state'),
    'locked', 'thread is locked' );
is( $threads->find('thread-1')->get_column('locked_at'),
    '2026-05-23T12:00:00Z', 'thread locked timestamp is stored' );

is( scalar @{ $moderation_actions->created },
    $CREATED_ACTIONS, 'moderation actions are inserted' );
is( $moderation_actions->created->[$FIRST_ACTION_INDEX]{action_type},
    'post.hidden', 'first action is hide' );
is( $moderation_actions->created->[$SECOND_ACTION_INDEX]{action_type},
    'post.restored', 'second action is restore' );
is( $moderation_actions->created->[$THIRD_ACTION_INDEX]{action_type},
    'thread.locked', 'third action is lock' );
is( scalar @{ $audit_log->created },
    $ACTION_AUDIT_ROWS, 'moderation actions create audit rows' );
is( $audit_log->created->[$CREATED_EVENTS]{action},
    'post.hidden', 'audit row stores action' );
is( $audit_log->created->[$CREATED_EVENTS]{metadata}{reason},
    'spam', 'audit row stores reason metadata' );
is( scalar @{ $event_log->created },
    $ACTION_AUDIT_ROWS, 'moderation actions create domain events' );
is( $event_log->created->[$CREATED_EVENTS]{event_type},
    'post.hidden', 'hide action records event type' );
is( scalar @{ $outbox_messages->created },
    $ACTION_AUDIT_ROWS, 'moderation actions create outbox handoffs' );

my $reversed =
  $action_store->reverse_action( 'generated-1', 'moderator-2',
    'appeal accepted' );
is( $reversed->{moderation_action_id},
    'generated-1', 'reversal returns action id' );
is( $reversed->{reversed_by_user_id}, 'moderator-2', 'reversal stores actor' );
is( $reversed->{reversed_at},
    '2026-05-23T12:00:00Z', 'reversal stores timestamp' );
is(
    $moderation_actions->find('generated-1')->get_column('reversed_by_user_id'),
    'moderator-2', 'action row is marked reversed'
);
is( scalar @{ $event_log->created },
    $MODERATION_EVENTS, 'moderation reversal creates a domain event' );
is( $event_log->created->[-1]{event_type},
    'moderation_action.reversed', 'reversal event type is explicit' );
is( scalar @{ $outbox_messages->created },
    $MODERATION_OUTBOX, 'moderation reversal creates outbox handoff' );
is( $audit_log->created->[-1]{action},
    'moderation_action.reversed', 'reversal records audit row' );
is(
    $audit_log->created->[-1]{metadata}{reason},
    'appeal accepted',
    'reversal audit stores reason'
);
my $reversal_events = scalar @{ $event_log->created };
my $same_reversal =
  $action_store->reverse_action( 'generated-1', 'moderator-2',
    'appeal accepted again' );
is( $same_reversal->{reversed_at},
    '2026-05-23T12:00:00Z', 'same reversal is idempotent' );
is( scalar @{ $event_log->created },
    $reversal_events, 'same reversal does not emit duplicate event' );

my $audit_review =
  GPForum::Service::Admin::AuditReview->new( schema => $schema, );
my $recent = $audit_review->recent( { limit => $AUDIT_LIMIT } );
is( scalar @{$recent}, $CREATED_AUDIT_ROWS, 'recent audit rows can be listed' );
is( $audit_log->last_attrs->{rows}, $AUDIT_LIMIT,
    'audit review applies limit' );

my $target_audit =
  $audit_review->for_target( 'post', 'post-1', { limit => $AUDIT_LIMIT } );
is( scalar @{$target_audit},
    $CREATED_AUDIT_ROWS, 'target audit rows can be listed' );
is( $audit_log->last_query->{target_type},
    'post', 'target audit filters target type' );
is( $audit_log->last_query->{target_id},
    'post-1', 'target audit filters target id' );

my $same_lock = $action_store->lock_thread(
    {
        actor_user_id => 'moderator-1',
        thread_id     => 'thread-1',
        reason        => 'heated discussion',
    }
);
ok( $same_lock->{ok}, 'same thread lock action succeeds' );
ok( $same_lock->{skipped},
    'same thread lock action is skipped when already locked' );
ok( $same_lock->{idempotent}, 'same thread lock action is marked idempotent' );
is(
    $same_lock->{action}{moderation_action_id},
    $locked->{action}{moderation_action_id},
    'same thread lock returns the original action'
);

my $hidden_thread = $action_store->hide_thread(
    {
        actor_user_id => 'moderator-1',
        thread_id     => 'thread-1',
        reason        => 'off-topic',
    }
);
ok( $hidden_thread->{ok}, 'thread hide action succeeds' );
is( $hidden_thread->{action}{action_type},
    'thread.hidden', 'hide thread action type stored' );
is( $threads->find('thread-1')->get_column('moderation_state'),
    'hidden', 'thread is hidden' );
is( $threads->find('thread-1')->get_column('hidden_at'),
    '2026-05-23T12:00:00Z', 'thread hidden timestamp is stored' );
is( $threads->find('thread-1')->get_column('locked_at'),
    '2026-05-23T12:00:00Z', 'thread hide keeps the lock timestamp' );

my $restored_thread = $action_store->restore_thread(
    {
        actor_user_id => 'moderator-1',
        thread_id     => 'thread-1',
        reason        => 'cleared',
    }
);
ok( $restored_thread->{ok}, 'thread restore action succeeds' );
is( $restored_thread->{action}{action_type},
    'thread.restored', 'restore thread action type stored' );
is( $threads->find('thread-1')->get_column('moderation_state'),
    'visible', 'thread is restored' );
is( $threads->find('thread-1')->get_column('hidden_at'),
    undef, 'thread hidden timestamp is cleared' );

my $suspension_store = GPForum::Service::Moderation::SuspensionStore->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);
my $suspension_event_start  = scalar @{ $event_log->created };
my $suspension_audit_start  = scalar @{ $audit_log->created };
my $suspension_outbox_start = scalar @{ $outbox_messages->created };
my $suspended               = $suspension_store->create_suspension(
    {
        actor_user_id => 'moderator-1',
        user_id       => 'user-2',
        reason        => 'abuse campaign',
        valid_to      => '2026-05-24T12:00:00Z',
    }
);
ok( $suspended->{ok}, 'user suspension succeeds' );
is( $suspended->{suspension}{suspension_id},
    'generated-1', 'suspension id is generated' );
is( $suspended->{suspension}{user_id},
    'user-2', 'suspension stores target user' );
is( $suspended->{suspension}{valid_from},
    '2026-05-23T12:00:00Z', 'suspension stores valid_from' );
is( $users->find('user-2')->get_column('status'),
    'suspended', 'user status is suspended' );
is( scalar @{ $suspensions->created }, 1, 'suspension row is inserted' );
is(
    scalar @{ $event_log->created },
    $suspension_event_start + 1,
    'suspension emits event'
);
is( $event_log->created->[-1]{event_type},
    'user.suspended', 'suspension event type is explicit' );
is(
    scalar @{ $outbox_messages->created },
    $suspension_outbox_start + 1,
    'suspension emits outbox handoff'
);
is(
    scalar @{ $audit_log->created },
    $suspension_audit_start + 1,
    'suspension emits audit row'
);
is( $audit_log->created->[-1]{action},
    'user.suspended', 'suspension audit action is explicit' );

my $suspension_events = scalar @{ $event_log->created };
my $same_suspension   = $suspension_store->create_suspension(
    {
        actor_user_id => 'moderator-1',
        user_id       => 'user-2',
        reason        => 'abuse campaign',
    }
);
is( $same_suspension->{suspension}{suspension_id},
    'generated-1', 'same active suspension returns existing row' );
is( scalar @{ $suspensions->created },
    1, 'same active suspension does not insert duplicate row' );
is( scalar @{ $event_log->created },
    $suspension_events,
    'same active suspension does not emit duplicate event' );

my $participation = $suspension_store->can_participate('user-2');
ok( !$participation->{ok}, 'suspended user cannot participate' );
is( $participation->{reason}, 'suspended', 'participation denial is explicit' );

my $revoked =
  $suspension_store->revoke_suspension( 'generated-1', 'moderator-2',
    'appeal accepted' );
is( $revoked->{suspension_id},
    'generated-1', 'suspension revocation returns suspension id' );
is( $revoked->{revoked_at},
    '2026-05-23T12:00:00Z', 'suspension revocation stores timestamp' );
is( $users->find('user-2')->get_column('status'),
    'active', 'user status is restored after revocation' );
is( $event_log->created->[-1]{event_type},
    'user.suspension_revoked', 'revocation event type is explicit' );
is( $audit_log->created->[-1]{action},
    'user.suspension_revoked', 'revocation audit action is explicit' );
is(
    $audit_log->created->[-1]{metadata}{reason},
    'appeal accepted',
    'revocation audit stores reason'
);
my $revocation_events = scalar @{ $event_log->created };
$clock->iso8601('2026-05-23T13:00:00Z');
my $same_revocation =
  $suspension_store->revoke_suspension( 'generated-1', 'moderator-2',
    'appeal accepted again' );
is( $same_revocation->{revoked_at},
    '2026-05-23T12:00:00Z', 'same revocation is idempotent' );
is( scalar @{ $event_log->created },
    $revocation_events, 'same revocation does not emit duplicate event' );
is( $users->find('user-2')->get_column('status'),
    'active', 'already-revoked retry keeps an active user active' );
is( $users->find('user-2')->get_column('updated_at'),
    '2026-05-23T12:00:00Z',
    'already-active user is not restamped on revoke retry' );

$users->find('user-2')->update(
    {
        status     => 'suspended',
        updated_at => '2026-05-23T11:00:00Z',
    }
);
my $restore_retry =
  $suspension_store->revoke_suspension( 'generated-1', 'moderator-2',
    'appeal accepted again' );
is( $restore_retry->{revoked_at},
    '2026-05-23T12:00:00Z',
    'incomplete restore retry keeps the original revoked timestamp' );
is( $users->find('user-2')->get_column('status'),
    'active', 'incomplete restore retry restores a still-suspended user' );
is( $users->find('user-2')->get_column('updated_at'),
    '2026-05-23T12:00:00Z',
    'incomplete restore retry uses the original revoked timestamp' );
is( scalar @{ $event_log->created },
    $revocation_events,
    'incomplete restore retry does not emit a second revoke event' );
$clock->iso8601('2026-05-23T12:00:00Z');

is(
    $suspension_store->create_suspension(
        {
            actor_user_id => 'moderator-1',
            user_id       => 'missing-user',
            reason        => 'missing',
        }
    ),
    undef,
    'missing user cannot be suspended'
);
is(
    $suspension_store->revoke_suspension(
        'missing-suspension', 'moderator-1', 'missing'
    ),
    undef,
    'missing suspension cannot be revoked'
);

my $suspension_pk_users = GPForum::Test::ModerationResultSet->new;
my $suspension_pk_rows =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$suspension_pk_users->create(
    {
        id         => 'user-pk',
        status     => 'active',
        updated_at => '2026-05-23T11:00:00Z',
    }
);
$suspension_pk_rows->create(
    {
        actor_user_id => 'moderator-1',
        reason        => 'other',
        suspension_id => 'generated-1',
        user_id       => 'user-other',
        valid_from    => '2026-05-23T12:00:00Z',
    }
);
my $suspension_pk_store = GPForum::Service::Moderation::SuspensionStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog      => GPForum::Test::ModerationResultSet->new,
            EventLog      => GPForum::Test::ModerationResultSet->new,
            OutboxMessage => GPForum::Test::ModerationResultSet->new,
            Suspension    => $suspension_pk_rows,
            User          => $suspension_pk_users,
        },
    ),
);
my $suspension_pk = $suspension_pk_store->create_suspension(
    {
        actor_user_id => 'moderator-1',
        reason        => 'pk remint',
        user_id       => 'user-pk',
    }
);
ok( $suspension_pk->{ok},
    'unique suspension id collision remints and suspends' );
is( $suspension_pk->{suspension}{suspension_id},
    'generated-2', 'unique suspension id collision remints the id' );
is( $suspension_pk->{suspension}{user_id},
    'user-pk', 'unique suspension id collision keeps this user' );
is( scalar @{ $suspension_pk_rows->created },
    2, 'unique suspension id collision inserts this suspension' );

$users->create(
    {
        id         => 'user-deleted',
        status     => 'deleted',
        updated_at => '2026-05-23T11:00:00Z',
    }
);
my $deleted_participation = $suspension_store->can_participate('user-deleted');
ok( !$deleted_participation->{ok}, 'deleted user cannot participate' );
is( $deleted_participation->{reason},
    'user_deleted', 'deleted participation denial is explicit' );

$suspensions->filter_search(1);
$users->create(
    {
        id         => 'user-3',
        status     => 'active',
        updated_at => '2026-05-23T11:00:00Z',
    }
);
$suspensions->create(
    {
        suspension_id => 'active-suspension',
        user_id       => 'user-3',
        revoked_at    => undef,
        valid_from    => '2026-05-23T10:00:00Z',
        valid_to      => undef,
    }
);
my $active_participation = $suspension_store->can_participate('user-3');
ok( !$active_participation->{ok}, 'active suspension blocks participation' );
is( $active_participation->{suspension_id},
    'active-suspension', 'active suspension denial exposes id' );

$users->create(
    {
        id         => 'user-4',
        status     => 'active',
        updated_at => '2026-05-23T11:00:00Z',
    }
);
$suspensions->create(
    {
        suspension_id => 'expired-suspension',
        user_id       => 'user-4',
        revoked_at    => undef,
        valid_from    => '2026-05-22T10:00:00Z',
        valid_to      => '2026-05-22T12:00:00Z',
    }
);
ok(
    $suspension_store->can_participate('user-4')->{ok},
    'expired suspension does not block participation'
);
is( $suspension_store->active_for_user('missing-user'),
    undef, 'missing user has no active suspension' );

my $review_actions = GPForum::Test::ModerationResultSet->new;
$review_actions->create(
    {
        moderation_action_id => 'action-a',
        actor_user_id        => 'moderator-1',
        action_type          => 'post.hidden',
        target_type          => 'post',
        target_id            => 'post-1',
        reason               => 'spam',
        metadata             => {},
        created_at           => '2026-05-23T12:00:00Z',
        reversed_at          => undef,
        reversed_by_user_id  => undef,
    }
);
$review_actions->create(
    {
        moderation_action_id => 'action-b',
        actor_user_id        => 'moderator-1',
        action_type          => 'thread.locked',
        target_type          => 'thread',
        target_id            => 'thread-1',
        reason               => 'heated discussion',
        metadata             => {},
        created_at           => '2026-05-23T11:00:00Z',
        reversed_at          => undef,
        reversed_by_user_id  => undef,
    }
);
$review_actions->create(
    {
        moderation_action_id => 'action-c',
        actor_user_id        => 'moderator-2',
        action_type          => 'post.restored',
        target_type          => 'post',
        target_id            => 'post-2',
        reason               => 'appeal',
        metadata             => {},
        created_at           => '2026-05-23T10:00:00Z',
        reversed_at          => undef,
        reversed_by_user_id  => undef,
    }
);
my $review_schema = GPForum::Test::ModerationSchema->new(
    resultsets => { ModerationAction => $review_actions } );
my $review_reader =
  GPForum::Service::Moderation::ReviewReader->new( schema => $review_schema );
my $action_page = $review_reader->list_actions(
    {
        limit       => 2,
        target_id   => 'post-1',
        target_type => 'post',
    }
);
is( scalar @{ $action_page->{items} },
    2, 'moderation action history applies keyset page size' );
ok( $action_page->{next_cursor}, 'moderation action history exposes cursor' );
is( $review_actions->last_attrs->{rows},
    $ACTION_FETCH_ROWS, 'moderation action history fetches one extra row' );
is( $review_actions->last_query->{target_type},
    'post', 'moderation action history filters target type' );
is( $review_actions->last_query->{target_id},
    'post-1', 'moderation action history filters target id' );

$review_reader->list_actions(
    {
        after => $action_page->{next_cursor},
        limit => 2,
    }
);
is(
    $review_actions->last_query->{-or}->[1]{-and}
      ->[1]{moderation_action_id}{q{<}},
    'action-b', 'moderation action history uses descending cursor predicate'
);

my $review_suspensions = GPForum::Test::ModerationResultSet->new;
$review_suspensions->create(
    {
        suspension_id => 'suspension-a',
        user_id       => 'user-2',
        actor_user_id => 'moderator-1',
        reason        => 'abuse campaign',
        valid_from    => '2026-05-23T12:00:00Z',
        valid_to      => undef,
        revoked_at    => undef,
        metadata      => {},
    }
);
$review_suspensions->create(
    {
        suspension_id => 'suspension-b',
        user_id       => 'user-3',
        actor_user_id => 'moderator-2',
        reason        => 'spam campaign',
        valid_from    => '2026-05-23T11:00:00Z',
        valid_to      => undef,
        revoked_at    => '2026-05-23T11:30:00Z',
        metadata      => {},
    }
);
my $suspension_review_schema = GPForum::Test::ModerationSchema->new(
    resultsets => { Suspension => $review_suspensions } );
my $suspension_reader = GPForum::Service::Moderation::ReviewReader->new(
    clock  => $clock,
    schema => $suspension_review_schema
);
my $suspension_page = $suspension_reader->list_suspensions(
    {
        limit   => 1,
        user_id => 'user-2',
    }
);
is( scalar @{ $suspension_page->{items} },
    1, 'suspension review applies keyset page size' );
ok( $suspension_page->{next_cursor}, 'suspension review exposes cursor' );
is( $review_suspensions->last_attrs->{rows},
    2, 'suspension review fetches one extra row' );
is( $review_suspensions->last_query->{revoked_at},
    undef, 'suspension review defaults to active rows' );
is( $review_suspensions->last_query->{user_id},
    'user-2', 'suspension review filters user' );
is( $review_suspensions->last_query->{-and}->[0]{-or}->[1]{valid_to}{q{>=}},
    '2026-05-23T12:00:00Z', 'suspension review excludes expired rows' );

$suspension_reader->list_suspensions(
    {
        limit  => 1,
        status => 'all',
    }
);
ok(
    !exists $review_suspensions->last_query->{revoked_at},
    'suspension review can include revoked rows'
);
is( $review_suspensions->last_attrs->{order_by}->[0]{-desc},
    'valid_from', 'suspension review sorts newest first' );

done_testing();

1;
