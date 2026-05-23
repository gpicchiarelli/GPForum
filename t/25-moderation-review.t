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
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS      => 61;
const my $QUEUE_LIMIT         => 25;
const my $AUDIT_LIMIT         => 10;
const my $CREATED_REPORTS     => 1;
const my $CREATED_EVENTS      => 3;
const my $CREATED_OUTBOX_ROWS => 3;
const my $FIRST_EVENT_COUNT   => 1;
const my $SECOND_EVENT_COUNT  => 2;
const my $CREATED_ACTIONS     => 3;
const my $CREATED_AUDIT_ROWS  => 6;
const my $FIRST_ACTION_INDEX  => 0;
const my $SECOND_ACTION_INDEX => 1;
const my $THIRD_ACTION_INDEX  => 2;
const my $FIRST_AUDIT_INDEX   => 0;
const my $SECOND_AUDIT_INDEX  => 1;
const my $THIRD_AUDIT_INDEX   => 2;

plan tests => $EXPECTED_TESTS;

my $reports            = GPForum::Test::ModerationResultSet->new;
my $moderation_actions = GPForum::Test::ModerationResultSet->new;
my $posts              = GPForum::Test::ModerationResultSet->new;
my $threads            = GPForum::Test::ModerationResultSet->new;
my $audit_log          = GPForum::Test::ModerationResultSet->new;
my $event_log          = GPForum::Test::ModerationResultSet->new;
my $outbox_messages    = GPForum::Test::ModerationResultSet->new;
my $schema             = GPForum::Test::ModerationSchema->new(
    resultsets => {
        Report           => $reports,
        ModerationAction => $moderation_actions,
        Post             => $posts,
        Thread           => $threads,
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

my $queue = $report_store->list_queue( { limit => $QUEUE_LIMIT } );
is( scalar @{$queue}, $CREATED_REPORTS,     'moderation queue can be listed' );
is( $reports->last_query->{status}, 'open', 'queue filters open reports' );
is( $reports->last_attrs->{rows},   $QUEUE_LIMIT, 'queue applies limit' );

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
is( $audit_log->created->[$THIRD_AUDIT_INDEX]{action},
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
    $CREATED_AUDIT_ROWS, 'moderation actions create audit rows' );
is( $audit_log->created->[$CREATED_EVENTS]{action},
    'post.hidden', 'audit row stores action' );
is( $audit_log->created->[$CREATED_EVENTS]{metadata}{reason},
    'spam', 'audit row stores reason metadata' );

my $reversed = $action_store->reverse_action( 'generated-1', 'moderator-2' );
is( $reversed->{moderation_action_id},
    'generated-1', 'reversal returns action id' );
is( $reversed->{reversed_by_user_id}, 'moderator-2', 'reversal stores actor' );
is( $reversed->{reversed_at},
    '2026-05-23T12:00:00Z', 'reversal stores timestamp' );
is(
    $moderation_actions->find('generated-1')->get_column('reversed_by_user_id'),
    'moderator-2', 'action row is marked reversed'
);

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

1;
