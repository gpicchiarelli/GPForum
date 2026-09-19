package main;

use strict;
use warnings;

use Const::Fast;
use Mojo::File qw(path);
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Migration::Plan;
use GPForum::Migration::Runner;
use GPForum::Schema;
use GPForum::Test::MigrationSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS               => 433;
const my $EXPECTED_MIGRATIONS          => 26;
const my $EXPECTED_RUNNER_EXECUTIONS   => 75;
const my $FORUM_MIGRATION_INDEX        => 2;
const my $GOVERNANCE_MIGRATION_INDEX   => 3;
const my $NOTIFICATION_MIGRATION_INDEX => 4;
const my $ATTACHMENT_MIGRATION_INDEX   => 5;
const my $ADVANCED_COMMUNITY_INDEX     => 6;
const my $MODERATION_REVIEW_INDEX      => 7;
const my $ADMIN_AUTHORIZATION_INDEX    => 8;
const my $IMPORT_EXPORT_INDEX          => 9;
const my $PLUGINS_INDEX                => 10;
const my $PERSONAL_FEED_INDEX          => 11;
const my $PUBLIC_PROFILE_INDEX         => 12;
const my $HOT_PATH_INDEX               => 13;
const my $SECURITY_ABUSE_INDEX         => 15;
const my $SEARCH_PRODUCT_INDEX         => 17;
const my $USER_LOCALE_INDEX            => 18;
const my $USER_THEME_INDEX             => 19;
const my $OUTBOX_RELIABILITY_INDEX     => 20;
const my $PRIVACY_IDEMPOTENCY_INDEX    => 23;
const my $IDENTITY_LIFECYCLE_INDEX     => 24;
const my $CONCURRENCY_UNIQUENESS_INDEX => 25;

plan tests => $EXPECTED_TESTS;

my $schema                         = GPForum::Schema->clone;
my $source                         = $schema->source('SchemaVersion');
my $event_source                   = $schema->source('EventLog');
my $audit_source                   = $schema->source('AuditLog');
my $outbox_source                  = $schema->source('OutboxMessage');
my $dead_letter_source             = $schema->source('DeadLetter');
my $notification_source            = $schema->source('Notification');
my $notification_inbox_source      = $schema->source('NotificationInbox');
my $notification_preference_source = $schema->source('NotificationPreference');
my $notification_read_source       = $schema->source('NotificationRead');
my $thread_read_state_source       = $schema->source('ThreadReadState');
my $read_marker_delta_source       = $schema->source('UserReadMarkerDelta');
my $attachment_source              = $schema->source('Attachment');
my $attachment_link_source         = $schema->source('AttachmentLink');
my $attachment_variant_source      = $schema->source('AttachmentVariant');
my $deletion_request_source        = $schema->source('DeletionRequest');
my $deletion_action_source         = $schema->source('DeletionAction');
my $erasure_job_source             = $schema->source('ErasureJob');
my $retention_hold_source          = $schema->source('RetentionHold');
my $bookmark_source                = $schema->source('Bookmark');
my $mention_source                 = $schema->source('Mention');
my $reputation_event_source        = $schema->source('ReputationEvent');
my $trust_score_snapshot_source    = $schema->source('TrustScoreSnapshot');
my $user_feed_item_source          = $schema->source('UserFeedItem');
my $report_source                  = $schema->source('Report');
my $moderation_action_source       = $schema->source('ModerationAction');
my $suspension_source              = $schema->source('Suspension');
my $role_source                    = $schema->source('Role');
my $permission_source              = $schema->source('Permission');
my $role_permission_source         = $schema->source('RolePermission');
my $role_binding_source            = $schema->source('RoleBinding');
my $resource_acl_source            = $schema->source('ResourceAcl');
my $projection_offset_source       = $schema->source('ProjectionOffset');
my $projection_generation_source   = $schema->source('ProjectionGeneration');
my $import_job_source              = $schema->source('ImportJob');
my $import_failure_source          = $schema->source('ImportFailure');
my $legacy_id_map_source           = $schema->source('LegacyIdMap');
my $export_request_source          = $schema->source('ExportRequest');
my $plugin_source                  = $schema->source('Plugin');
my $plugin_hook_source             = $schema->source('PluginHook');
my $plugin_failure_source          = $schema->source('PluginFailure');
my $rate_limit_bucket_source       = $schema->source('RateLimitBucket');

is( $source->from, 'schema_versions', 'schema version source maps table' );
is_deeply( [ $source->primary_columns ],
    ['version'], 'schema version primary key is explicit' );
ok( $source->has_column('checksum'), 'schema version records checksums' );
ok(
    $source->has_column('applied_at'),
    'schema version records application time'
);

is( $event_source->from, 'event_log', 'event source maps event log table' );
is_deeply(
    [ $event_source->primary_columns ],
    [ 'event_id', 'created_at' ],
    'event log primary key is partition-safe'
);
ok( $event_source->has_column('event_type'), 'event log stores event type' );
ok(
    $event_source->has_column('schema_version'),
    'event log stores schema version'
);
ok(
    $event_source->has_column('correlation_id'),
    'event log stores correlation id'
);
ok( $event_source->has_column('causation_id'),
    'event log stores causation id' );
ok(
    $event_source->has_column('aggregate_version'),
    'event log stores aggregate stream version'
);
ok(
    $event_source->has_column('idempotency_key'),
    'event log stores idempotency key'
);
ok( $event_source->has_column('payload'), 'event log stores payload' );

is( $audit_source->from, 'audit_log', 'audit source maps audit log table' );
is_deeply(
    [ $audit_source->primary_columns ],
    [ 'audit_id', 'created_at' ],
    'audit log primary key is partition-safe'
);
ok( $audit_source->has_column('action'), 'audit log stores action' );
ok(
    $audit_source->has_column('schema_version'),
    'audit log stores schema version'
);
ok(
    $audit_source->has_column('correlation_id'),
    'audit log stores correlation id'
);
ok(
    $audit_source->has_column('previous_hash'),
    'audit log supports hash chain previous hash'
);
ok(
    $audit_source->has_column('record_hash'),
    'audit log supports hash chain record hash'
);
ok( $audit_source->has_column('metadata'), 'audit log stores metadata' );

is( $outbox_source->from, 'outbox_messages',
    'outbox source maps outbox messages table' );
is_deeply( [ $outbox_source->primary_columns ],
    ['outbox_id'], 'outbox primary key is explicit' );
ok( $outbox_source->has_column('event_id'), 'outbox links to event id' );
ok( $outbox_source->has_column('queue'),    'outbox stores queue' );
ok( $outbox_source->has_column('job_type'), 'outbox stores job type' );
ok( $outbox_source->has_column('next_attempt_at'),
    'outbox stores retry schedule' );
ok(
    $outbox_source->has_column('failure_type'),
    'outbox stores classified failure type'
);

is( $dead_letter_source->from, 'dead_letters',
    'dead letter source maps dead letters table' );
is_deeply( [ $dead_letter_source->primary_columns ],
    ['dead_letter_id'], 'dead letter primary key is explicit' );
ok( $dead_letter_source->has_column('source_table'),
    'dead letter stores source table' );
ok( $dead_letter_source->has_column('source_id'),
    'dead letter stores source id' );
ok( $dead_letter_source->has_column('error_class'),
    'dead letter stores error class' );
ok( $dead_letter_source->has_column('retry_count'),
    'dead letter stores retry count' );
ok(
    $dead_letter_source->has_column('failure_type'),
    'dead letter stores classified failure type'
);

is( $notification_source->from,
    'notifications', 'notification source maps notifications table' );
is_deeply(
    [ $notification_source->primary_columns ],
    [ 'notification_id', 'created_at' ],
    'notification primary key is partition-safe'
);
ok( $notification_source->has_column('payload'),
    'notification stores payload' );
ok( $notification_source->has_relationship('recipient'),
    'notification belongs to recipient' );
ok(
    $notification_source->has_relationship('inbox_entries'),
    'notification has inbox projection entries'
);

is( $notification_read_source->from,
    'notification_reads', 'notification read source maps reads table' );
is_deeply(
    [ $notification_read_source->primary_columns ],
    [ 'notification_id', 'recipient_user_id' ],
    'notification read primary key is explicit'
);
ok( $notification_read_source->has_column('read_at'),
    'notification read stores timestamp' );

is( $thread_read_state_source->from,
    'thread_read_state', 'thread read state source maps read markers' );
is_deeply(
    [ $thread_read_state_source->primary_columns ],
    [ 'user_id', 'thread_id' ],
    'thread read state primary key is explicit'
);
ok( $thread_read_state_source->has_column('last_read_position'),
    'thread read state stores last read position' );
ok(
    $thread_read_state_source->has_column('last_read_at'),
    'thread read state stores read timestamp'
);
ok( $thread_read_state_source->has_relationship('thread'),
    'thread read state belongs to thread' );

is( $read_marker_delta_source->from,
    'user_read_marker_deltas', 'read marker delta source maps delta table' );
is_deeply(
    [ $read_marker_delta_source->primary_columns ],
    [ 'user_id', 'thread_id' ],
    'read marker delta primary key is explicit'
);
ok( $read_marker_delta_source->has_column('last_read_position'),
    'read marker delta stores last read position' );
ok(
    $read_marker_delta_source->has_column('last_read_at'),
    'read marker delta stores read timestamp'
);
ok( $read_marker_delta_source->has_relationship('thread'),
    'read marker delta belongs to thread' );

is( $notification_inbox_source->from,
    'notification_inbox', 'notification inbox source maps inbox table' );
is_deeply(
    [ $notification_inbox_source->primary_columns ],
    [ 'recipient_user_id', 'notification_id' ],
    'notification inbox primary key is explicit'
);
ok( $notification_inbox_source->has_column('rank_score'),
    'notification inbox stores rank score' );
ok(
    $notification_inbox_source->has_relationship('notification'),
    'notification inbox belongs to notification payload'
);

is( $notification_preference_source->from,
    'notification_preferences',
    'notification preference source maps preferences table' );
is_deeply(
    [ $notification_preference_source->primary_columns ],
    [ 'user_id', 'channel' ],
    'notification preference primary key is explicit'
);
ok(
    $notification_preference_source->has_column('digest_frequency'),
    'notification preference stores digest frequency'
);
ok( $notification_preference_source->has_relationship('user'),
    'notification preference belongs to user' );

is( $attachment_source->from, 'attachments', 'attachment source maps table' );
is_deeply( [ $attachment_source->primary_columns ],
    ['attachment_id'], 'attachment primary key is explicit' );
ok( $attachment_source->has_column('owner_user_id'),
    'attachment stores owner' );
ok( $attachment_source->has_column('object_key'),
    'attachment stores object key' );
ok(
    $attachment_source->has_column('state'),
    'attachment stores lifecycle state'
);
ok( $attachment_source->has_column('scan_status'),
    'attachment stores scan status' );
is( $attachment_link_source->from,
    'attachment_links', 'attachment link source maps table' );
is_deeply( [ $attachment_link_source->primary_columns ],
    ['attachment_link_id'], 'attachment link primary key is explicit' );
ok( $attachment_link_source->has_column('target_type'),
    'attachment link stores target type' );
ok( $attachment_link_source->has_column('target_id'),
    'attachment link stores target id' );
is( $attachment_variant_source->from,
    'attachment_variants', 'attachment variant source maps table' );
is_deeply( [ $attachment_variant_source->primary_columns ],
    ['attachment_variant_id'], 'attachment variant primary key is explicit' );
ok( $attachment_variant_source->has_column('variant_type'),
    'attachment variant stores variant type' );
ok( $attachment_variant_source->has_column('object_key'),
    'attachment variant stores object key' );

is( $deletion_request_source->from,
    'deletion_requests', 'deletion request source maps table' );
is_deeply( [ $deletion_request_source->primary_columns ],
    ['deletion_request_id'], 'deletion request primary key is explicit' );
ok( $deletion_request_source->has_column('request_type'),
    'deletion request stores request type' );
ok( $deletion_request_source->has_relationship('actions'),
    'deletion request has actions' );
ok( $deletion_request_source->has_relationship('erasure_jobs'),
    'deletion request has erasure jobs' );

is( $deletion_action_source->from,
    'deletion_actions', 'deletion action source maps table' );
is_deeply( [ $deletion_action_source->primary_columns ],
    ['deletion_action_id'], 'deletion action primary key is explicit' );
ok( $deletion_action_source->has_column('action_type'),
    'deletion action stores action type' );
ok( $deletion_action_source->has_relationship('deletion_request'),
    'deletion action belongs to deletion request' );

is( $erasure_job_source->from,
    'erasure_jobs', 'erasure job source maps table' );
is_deeply( [ $erasure_job_source->primary_columns ],
    ['erasure_job_id'], 'erasure job primary key is explicit' );
ok( $erasure_job_source->has_column('last_error'),
    'erasure job stores last error' );
is_deeply(
    [
        $erasure_job_source->unique_constraint_columns(
            'erasure_jobs_request_key')
    ],
    ['deletion_request_id'],
    'erasure job is unique per deletion request'
);
ok( $erasure_job_source->has_relationship('deletion_request'),
    'erasure job belongs to deletion request' );

is( $retention_hold_source->from,
    'retention_holds', 'retention hold source maps table' );
is_deeply( [ $retention_hold_source->primary_columns ],
    ['retention_hold_id'], 'retention hold primary key is explicit' );
ok(
    $retention_hold_source->has_column('ends_at'),
    'retention hold stores end timestamp'
);

is( $bookmark_source->from, 'bookmarks', 'bookmark source maps table' );
is_deeply( [ $bookmark_source->primary_columns ],
    ['bookmark_id'], 'bookmark primary key is explicit' );
ok( $bookmark_source->has_column('note'),       'bookmark stores note' );
ok( $bookmark_source->has_relationship('user'), 'bookmark belongs to user' );

is( $mention_source->from, 'mentions', 'mention source maps table' );
is_deeply( [ $mention_source->primary_columns ],
    ['mention_id'], 'mention primary key is explicit' );
ok( $mention_source->has_column('mentioned_username'),
    'mention stores username snapshot' );
ok( $mention_source->has_relationship('actor'), 'mention belongs to actor' );
ok( $mention_source->has_relationship('mentioned_user'),
    'mention belongs to mentioned user' );

is( $reputation_event_source->from,
    'reputation_events', 'reputation event source maps table' );
is_deeply( [ $reputation_event_source->primary_columns ],
    ['reputation_event_id'], 'reputation event primary key is explicit' );
ok( $reputation_event_source->has_column('delta'),
    'reputation event stores delta' );
ok( $reputation_event_source->has_relationship('user'),
    'reputation event belongs to user' );

is( $trust_score_snapshot_source->from,
    'trust_score_snapshots', 'trust score snapshot source maps table' );
is_deeply( [ $trust_score_snapshot_source->primary_columns ],
    ['user_id'], 'trust score snapshot primary key is user' );
ok( $trust_score_snapshot_source->has_column('trust_level'),
    'trust score snapshot stores trust level' );
ok( $trust_score_snapshot_source->has_relationship('user'),
    'trust score snapshot belongs to user' );

is( $user_feed_item_source->from,
    'user_feed_items', 'user feed item source maps table' );
is_deeply(
    [ $user_feed_item_source->primary_columns ],
    [ 'user_id', 'item_type', 'item_id' ],
    'user feed item primary key is explicit'
);
ok( $user_feed_item_source->has_column('rank_score'),
    'user feed item stores rank score' );
ok( $user_feed_item_source->has_column('permission_version'),
    'user feed item stores permission version' );
ok( $user_feed_item_source->has_relationship('user'),
    'user feed item belongs to user' );

is( $report_source->from, 'reports', 'report source maps table' );
is_deeply( [ $report_source->primary_columns ],
    ['report_id'], 'report primary key is explicit' );
ok( $report_source->has_column('status'),     'report stores status' );
ok( $report_source->has_column('resolution'), 'report stores resolution' );
ok( $report_source->has_relationship('reporter'),
    'report belongs to reporter' );

is( $moderation_action_source->from,
    'moderation_actions', 'moderation action source maps table' );
is_deeply( [ $moderation_action_source->primary_columns ],
    ['moderation_action_id'], 'moderation action primary key is explicit' );
ok( $moderation_action_source->has_column('action_type'),
    'moderation action stores action type' );
ok( $moderation_action_source->has_column('command_id'),
    'moderation action stores command id' );
is_deeply(
    [
        $moderation_action_source->unique_constraint_columns(
            'moderation_actions_command_key')
    ],
    ['command_id'],
    'moderation action command id is unique'
);
ok( $moderation_action_source->has_column('reversed_at'),
    'moderation action supports reversal' );
ok( $moderation_action_source->has_relationship('actor'),
    'moderation action belongs to actor' );

is( $suspension_source->from, 'suspensions', 'suspension source maps table' );
is_deeply( [ $suspension_source->primary_columns ],
    ['suspension_id'], 'suspension primary key is explicit' );
ok( $suspension_source->has_column('valid_from'),
    'suspension stores valid_from' );
ok( $suspension_source->has_column('revoked_at'),
    'suspension supports revocation' );
ok( $suspension_source->has_relationship('user'),
    'suspension belongs to user' );

is( $role_source->from, 'roles', 'role source maps table' );
is_deeply( [ $role_source->primary_columns ],
    ['role_id'], 'role primary key is explicit' );
ok( $role_source->has_column('name'), 'role stores name' );
ok( $role_source->has_relationship('role_permissions'),
    'role has role permissions' );
ok( $role_source->has_relationship('role_bindings'), 'role has role bindings' );

is( $permission_source->from, 'permissions', 'permission source maps table' );
is_deeply( [ $permission_source->primary_columns ],
    ['permission_id'], 'permission primary key is explicit' );
ok( $permission_source->has_column('resource_type'),
    'permission stores resource type' );
ok( $permission_source->has_column('action'), 'permission stores action' );
ok( $permission_source->has_relationship('role_permissions'),
    'permission has role permissions' );

is( $role_permission_source->from,
    'role_permissions', 'role permission source maps table' );
is_deeply(
    [ $role_permission_source->primary_columns ],
    [ 'role_id', 'permission_id' ],
    'role permission primary key is explicit'
);
ok( $role_permission_source->has_relationship('role'),
    'role permission belongs to role' );
ok( $role_permission_source->has_relationship('permission'),
    'role permission belongs to permission' );

is( $role_binding_source->from,
    'role_bindings', 'role binding source maps table' );
is_deeply( [ $role_binding_source->primary_columns ],
    ['binding_id'], 'role binding primary key is explicit' );
ok( $role_binding_source->has_column('created_by_user_id'),
    'role binding stores creator' );
ok( $role_binding_source->has_relationship('user'),
    'role binding belongs to user' );
ok( $role_binding_source->has_relationship('role'),
    'role binding belongs to role' );

is( $resource_acl_source->from,
    'resource_acl', 'resource acl source maps table' );
is_deeply( [ $resource_acl_source->primary_columns ],
    ['acl_id'], 'resource acl primary key is explicit' );
ok( $resource_acl_source->has_column('permission_id'),
    'resource acl stores permission' );
ok( $resource_acl_source->has_relationship('permission'),
    'resource acl belongs to permission' );

is( $projection_offset_source->from,
    'projection_offsets',
    'projection offset source maps projection offsets table' );
is_deeply( [ $projection_offset_source->primary_columns ],
    ['projection_name'], 'projection offset primary key is explicit' );
ok( $projection_offset_source->has_column('last_event_id'),
    'projection offset stores last event id' );
ok( $projection_offset_source->has_column('lag_seconds'),
    'projection offset stores lag seconds' );
ok( $projection_offset_source->has_column('status'),
    'projection offset stores status' );

is( $projection_generation_source->from,
    'projection_generations',
    'projection generation source maps projection generations table' );
is_deeply( [ $projection_generation_source->primary_columns ],
    ['generation_id'], 'projection generation primary key is explicit' );
ok(
    $projection_generation_source->has_column('is_active'),
    'projection generation stores active marker'
);

is( $import_job_source->from, 'import_jobs', 'import job source maps table' );
is_deeply( [ $import_job_source->primary_columns ],
    ['import_job_id'], 'import job primary key is explicit' );
ok(
    $import_job_source->has_column('manifest'),
    'import job stores source manifest'
);
ok(
    $import_job_source->has_column('progress'),
    'import job stores progress snapshot'
);
ok( $import_job_source->has_relationship('failures'),
    'import job has failure rows' );

is( $import_failure_source->from,
    'import_failures', 'import failure source maps table' );
is_deeply( [ $import_failure_source->primary_columns ],
    ['import_failure_id'], 'import failure primary key is explicit' );
ok( $import_failure_source->has_column('error_code'),
    'import failure stores error code' );
ok( $import_failure_source->has_relationship('import_job'),
    'import failure belongs to import job' );

is( $legacy_id_map_source->from,
    'legacy_id_map', 'legacy id map source maps table' );
is_deeply( [ $legacy_id_map_source->primary_columns ],
    ['legacy_id_map_id'], 'legacy id map primary key is explicit' );
ok( $legacy_id_map_source->has_column('canonical_url'),
    'legacy id map stores canonical urls' );
ok( $legacy_id_map_source->has_relationship('import_job'),
    'legacy id map belongs to import job' );

is( $export_request_source->from,
    'export_requests', 'export request source maps table' );
is_deeply( [ $export_request_source->primary_columns ],
    ['export_request_id'], 'export request primary key is explicit' );
ok( $export_request_source->has_column('export_type'),
    'export request stores export type' );
ok( $export_request_source->has_relationship('requester'),
    'export request belongs to requester' );
ok( $export_request_source->has_relationship('subject'),
    'export request belongs to subject' );

is( $plugin_source->from, 'plugins', 'plugin source maps table' );
is_deeply( [ $plugin_source->primary_columns ],
    ['plugin_id'], 'plugin primary key is explicit' );
ok( $plugin_source->has_column('compatible_gpforum_range'),
    'plugin stores compatibility range' );
ok( $plugin_source->has_relationship('hooks'),    'plugin has hooks' );
ok( $plugin_source->has_relationship('failures'), 'plugin has failures' );

is( $plugin_hook_source->from,
    'plugin_hooks', 'plugin hook source maps table' );
is_deeply( [ $plugin_hook_source->primary_columns ],
    ['hook_id'], 'plugin hook primary key is explicit' );
ok( $plugin_hook_source->has_column('side_effect_policy'),
    'plugin hook stores side-effect policy' );
ok( $plugin_hook_source->has_relationship('plugin'),
    'plugin hook belongs to plugin' );

is( $plugin_failure_source->from,
    'plugin_failures', 'plugin failure source maps table' );
is_deeply( [ $plugin_failure_source->primary_columns ],
    ['plugin_failure_id'], 'plugin failure primary key is explicit' );
ok( $plugin_failure_source->has_column('error_class'),
    'plugin failure stores error class' );
ok( $plugin_failure_source->has_relationship('plugin'),
    'plugin failure belongs to plugin' );

my $user_source           = $schema->source('User');
my $credential_source     = $schema->source('Credential');
my $identity_token_source = $schema->source('IdentityToken');
my $session_source        = $schema->source('Session');
my $space_source          = $schema->source('Space');
my $subscription_source   = $schema->source('Subscription');
my $category_source       = $schema->source('Category');
my $thread_source         = $schema->source('Thread');
my $post_source           = $schema->source('Post');
my $body_source           = $schema->source('PostBody');
my $revision_source       = $schema->source('PostRevision');
my $counter_source        = $schema->source('ThreadCounter');
my $counter_shard_source  = $schema->source('ThreadCounterShard');
my $stat_source           = $schema->source('CategoryStat');
my $search_source         = $schema->source('SearchDocument');

is( $user_source->from, 'users', 'user source maps users table' );
is_deeply( [ $user_source->primary_columns ],
    ['id'], 'user primary key is explicit' );
ok( $user_source->has_column('email_normalized'),
    'user stores normalized email' );
ok(
    $user_source->has_column('email_verified_at'),
    'user supports email verification placeholder'
);
ok( $user_source->has_column('version'), 'user supports optimistic locking' );
ok(
    $user_source->has_column('permission_version'),
    'user supports permission cache invalidation'
);
ok( $user_source->has_column('preferred_locale'),
    'user stores preferred UI locale' );
ok( $user_source->has_column('preferred_theme'),
    'user stores preferred UI theme' );
ok(
    $user_source->has_relationship('credentials'),
    'user has credentials relationship'
);
ok( $user_source->has_relationship('sessions'),
    'user has sessions relationship' );
ok(
    $user_source->has_relationship('identity_tokens'),
    'user has identity token relationship'
);
ok(
    $user_source->has_relationship('thread_read_states'),
    'user has thread read states relationship'
);
ok(
    $user_source->has_relationship('read_marker_deltas'),
    'user has read marker delta relationship'
);
ok(
    $user_source->has_relationship('bookmarks'),
    'user has bookmarks relationship'
);
ok(
    $user_source->has_relationship('subscriptions'),
    'user has subscriptions relationship'
);
ok(
    $user_source->has_relationship('authored_mentions'),
    'user has authored mentions relationship'
);
ok(
    $user_source->has_relationship('mentions'),
    'user has received mentions relationship'
);

is( $credential_source->from, 'credentials',
    'credential source maps credentials table' );
ok(
    $credential_source->has_column('secret_hash'),
    'credential stores only secret hash'
);
ok( $credential_source->has_relationship('user'),
    'credential belongs to user' );

is( $identity_token_source->from,
    'identity_tokens', 'identity token source maps identity_tokens table' );
is_deeply( [ $identity_token_source->primary_columns ],
    ['token_id'], 'identity token primary key is explicit' );
ok(
    $identity_token_source->has_column('token_hash'),
    'identity token stores only token hash'
);
ok(
    $identity_token_source->has_column('email_normalized'),
    'identity token stores pending email target'
);
ok(
    $identity_token_source->has_column('used_at'),
    'identity token supports one-time use'
);
is_deeply(
    [
        $identity_token_source->unique_constraint_columns(
            'identity_tokens_hash_key')
    ],
    ['token_hash'],
    'identity token hash is unique'
);
ok( $identity_token_source->has_relationship('user'),
    'identity token belongs to user' );

is( $session_source->from, 'sessions', 'session source maps sessions table' );
is_deeply( [ $session_source->primary_columns ],
    ['session_id'], 'session primary key is explicit' );
ok( $session_source->has_column('session_hash'), 'session stores token hash' );
ok( $session_source->has_column('revoked_at'), 'session supports revocation' );
ok( $session_source->has_relationship('user'), 'session belongs to user' );

is( $rate_limit_bucket_source->from,
    'rate_limit_buckets', 'rate limit source maps buckets table' );
is_deeply(
    [ $rate_limit_bucket_source->primary_columns ],
    [qw(scope actor_hash action window_started_at)],
    'rate limit bucket primary key is scoped by window'
);
ok( $rate_limit_bucket_source->has_column('observed_count'),
    'rate limit bucket stores observed count' );
ok( $rate_limit_bucket_source->has_column('blocked_count'),
    'rate limit bucket stores blocked count' );
ok( $rate_limit_bucket_source->has_column('expires_at'),
    'rate limit bucket stores expiry' );

is( $space_source->from, 'spaces', 'space source maps spaces table' );
is_deeply( [ $space_source->primary_columns ],
    ['space_id'], 'space primary key is explicit' );
ok(
    $space_source->has_relationship('categories'),
    'space has categories relationship'
);

is( $subscription_source->from,
    'subscriptions', 'subscription source maps subscriptions table' );
is_deeply( [ $subscription_source->primary_columns ],
    ['subscription_id'], 'subscription primary key is explicit' );
ok( $subscription_source->has_column('preference'),
    'subscription stores preference' );
ok( $subscription_source->has_relationship('user'),
    'subscription belongs to user' );

is( $category_source->from, 'categories',
    'category source maps categories table' );
is_deeply( [ $category_source->primary_columns ],
    ['category_id'], 'category primary key is explicit' );
ok( $category_source->has_relationship('space'), 'category belongs to space' );
ok(
    $category_source->has_relationship('threads'),
    'category has threads relationship'
);
ok(
    $category_source->has_relationship('stats'),
    'category has stats projection relationship'
);

is( $thread_source->from, 'threads', 'thread source maps threads table' );
is_deeply( [ $thread_source->primary_columns ],
    ['thread_id'], 'thread primary key is explicit' );
ok( $thread_source->has_column('visibility_version'),
    'thread stores visibility version' );
ok( $thread_source->has_column('permission_version'),
    'thread stores permission version' );
ok( $thread_source->has_relationship('category'),
    'thread belongs to category' );
ok( $thread_source->has_relationship('author'), 'thread belongs to author' );
ok( $thread_source->has_relationship('posts'),
    'thread has posts relationship' );
ok(
    $thread_source->has_relationship('counters'),
    'thread has counters projection relationship'
);
ok(
    $thread_source->has_relationship('read_states'),
    'thread has read states relationship'
);
ok(
    $thread_source->has_relationship('read_marker_deltas'),
    'thread has read marker delta relationship'
);

is( $post_source->from, 'posts', 'post source maps posts table' );
is_deeply( [ $post_source->primary_columns ],
    ['post_id'], 'post primary key is explicit' );
ok(
    $post_source->has_column('current_body_id'),
    'post stores current body pointer'
);
ok(
    $post_source->has_column('current_revision_id'),
    'post stores current revision pointer'
);
ok( $post_source->has_column('position'),     'post stores thread position' );
ok( $post_source->has_relationship('thread'), 'post belongs to thread' );
ok( $post_source->has_relationship('author'), 'post belongs to author' );
ok( $post_source->has_relationship('bodies'), 'post has bodies' );
ok( $post_source->has_relationship('revisions'), 'post has revisions' );
ok(
    $post_source->has_relationship('current_body'),
    'post has current body relationship'
);
ok(
    $post_source->has_relationship('current_revision'),
    'post has current revision relationship'
);

is( $body_source->from, 'post_bodies',
    'post body source maps post bodies table' );
is_deeply( [ $body_source->primary_columns ],
    ['body_id'], 'post body primary key is explicit' );
ok( $body_source->has_column('source_hash'), 'post body stores content hash' );
ok( $body_source->has_relationship('post'),  'post body belongs to post' );

is( $revision_source->from, 'post_revisions',
    'post revision source maps revisions table' );
is_deeply( [ $revision_source->primary_columns ],
    ['revision_id'], 'post revision primary key is explicit' );
ok( $revision_source->has_relationship('post'),
    'post revision belongs to post' );
ok( $revision_source->has_relationship('body'),
    'post revision belongs to body' );
ok( $revision_source->has_relationship('editor'),
    'post revision belongs to editor' );

is( $counter_source->from, 'thread_counters',
    'thread counter source maps projection table' );
ok(
    $counter_source->has_relationship('thread'),
    'thread counter belongs to thread'
);

is( $counter_shard_source->from,
    'thread_counter_shards',
    'thread counter shard source maps anti-hot-row projection table' );
is_deeply(
    [ $counter_shard_source->primary_columns ],
    [ 'thread_id', 'shard_id' ],
    'thread counter shard primary key is explicit'
);
ok(
    $counter_shard_source->has_column('reply_count_delta'),
    'thread counter shard stores reply count deltas'
);
ok(
    $counter_shard_source->has_relationship('thread'),
    'thread counter shard belongs to thread'
);

is( $stat_source->from, 'category_stats',
    'category stat source maps projection table' );
ok(
    $stat_source->has_relationship('category'),
    'category stat belongs to category'
);

is( $search_source->from, 'search_documents',
    'search document source maps search projection table' );
ok(
    $search_source->has_column('search_vector'),
    'search document stores search vector'
);
ok(
    $search_source->has_column('source_version'),
    'search document stores source version'
);
ok(
    $search_source->has_column('category_id'),
    'search document stores category filter'
);
ok(
    $search_source->has_column('author_user_id'),
    'search document stores author filter'
);
ok(
    $search_source->has_column('source_created_at'),
    'search document stores source creation time'
);

my $config = GPForum::Config->from_environment(
    {
        GPFORUM_DATABASE_DSN  => 'dbi:Pg:dbname=gpforum_test',
        GPFORUM_DATABASE_USER => 'gpforum_test',
    }
);
my $connected_schema = GPForum::Schema->connect_from_config($config);

isa_ok( $connected_schema, 'GPForum::Schema' );
is( $connected_schema->storage->connect_info->[0],
    $config->database_dsn, 'schema uses configured database dsn' );

my $plan    = GPForum::Migration::Plan->new;
my $summary = $plan->summary;

is( scalar @{$summary}, $EXPECTED_MIGRATIONS, 'all migrations are planned' );
is( $summary->[0]->{version}, '001',          'migration version is parsed' );
is(
    $summary->[0]->{description},
    'core identity',
    'migration description is parsed'
);

my $migration_sql = path( $summary->[0]->{file} )->slurp;

like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] schema_versions/msx,
    'migration creates schema_versions table'
);
like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] users/msx,
    'core identity migration creates users table'
);
like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] credentials/msx,
    'core identity migration creates credentials table'
);
like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] sessions/msx,
    'core identity migration creates sessions table'
);
like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] roles/msx,
    'core identity migration creates roles table'
);
like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] role_bindings/msx,
    'core identity migration creates role bindings table'
);
like(
    $migration_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] resource_acl/msx,
    'core identity migration creates resource acl table'
);

my $event_audit_sql = path( $summary->[1]->{file} )->slurp;

is( $summary->[1]->{description},
    'event audit', 'event audit migration description is parsed' );
like(
    $event_audit_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] event_log/msx,
    'event audit migration creates event log table'
);
like(
    $event_audit_sql,
    qr/PARTITION [ ] BY [ ] RANGE [ ] [(] created_at [)]/msx,
    'event audit migration partitions append logs by created_at'
);
like(
    $event_audit_sql,
qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] event_idempotency_keys/msx,
    'event audit migration creates global idempotency table'
);
like( $event_audit_sql, qr/aggregate_version/msx,
    'event audit migration stores aggregate versions' );
like(
    $event_audit_sql,
    qr/aggregate_stream_versions/msx,
    'event audit migration creates aggregate stream version guard'
);
like( $event_audit_sql, qr/previous_hash/msx,
    'event audit migration stores audit hash chain links' );
like(
    $event_audit_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] idempotency_keys/msx,
    'event audit migration creates command idempotency table'
);
like(
    $event_audit_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] audit_log/msx,
    'event audit migration creates audit log table'
);
like(
    $event_audit_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] outbox_messages/msx,
    'event audit migration creates outbox messages table'
);
like(
    $event_audit_sql,
    qr/USING [ ] BRIN [ ] [(] created_at [)]/msx,
    'event audit migration creates BRIN indexes for append logs'
);

my $forum_projection_sql =
  path( $summary->[$FORUM_MIGRATION_INDEX]->{file} )->slurp;

is(
    $summary->[$FORUM_MIGRATION_INDEX]->{description},
    'forum projection',
    'forum projection migration description is parsed'
);
like(
    $forum_projection_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] spaces/msx,
    'forum projection migration creates spaces table'
);
like(
    $forum_projection_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] categories/msx,
    'forum projection migration creates categories table'
);
like(
    $forum_projection_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] threads/msx,
    'forum projection migration creates threads table'
);
like(
    $forum_projection_sql,
    qr/INCLUDE [ ] [(] title, [ ] author_user_id [)]/msx,
    'forum projection migration uses a covering thread list index'
);
like(
    $forum_projection_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] posts/msx,
    'forum projection migration creates posts metadata table'
);
like(
    $forum_projection_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] posts_archive/msx,
    'forum projection migration creates post archive table'
);
like(
    $forum_projection_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] post_bodies/msx,
    'forum projection migration separates post body storage'
);
like(
    $forum_projection_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] post_revisions/msx,
    'forum projection migration creates append revision table'
);
like(
    $forum_projection_sql,
    qr/WHERE [ ] deleted_at [ ] IS [ ] NULL [ ] AND [ ] moderation_state/msx,
    'forum projection migration creates visible-content partial indexes'
);
like(
    $forum_projection_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] thread_counters/msx,
    'forum projection migration creates thread counters projection'
);
like(
    $forum_projection_sql,
    qr/WITH [ ] [(] fillfactor [ ] = [ ] 80 [)]/msx,
    'forum projection migration tunes fillfactor for hot projections'
);
like(
    $forum_projection_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] search_documents/msx,
    'forum projection migration creates rebuildable search documents'
);
like( $forum_projection_sql, qr/visibility_version/msx,
    'forum projection migration stores visibility snapshot versions' );
like( $forum_projection_sql, qr/permission_version/msx,
    'forum projection migration stores permission snapshot versions' );
like(
    $forum_projection_sql,
    qr/USING [ ] GIN [ ] [(] search_vector [)]/msx,
    'forum projection migration indexes search vectors'
);
like( $forum_projection_sql, qr/gin_trgm_ops/msx,
    'forum projection migration indexes normalized search titles with trigram'
);
like(
    $forum_projection_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] notifications/msx,
    'forum projection migration creates notifications table'
);
like(
    $forum_projection_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] notification_reads/msx,
    'forum projection migration separates notification reads'
);
like(
    $forum_projection_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] notification_inbox/msx,
    'forum projection migration creates notification inbox projection'
);
like(
    $forum_projection_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] user_feed_items/msx,
    'forum projection migration creates user feed projection'
);

my $platform_governance_sql =
  path( $summary->[$GOVERNANCE_MIGRATION_INDEX]->{file} )->slurp;

is(
    $summary->[$GOVERNANCE_MIGRATION_INDEX]->{description},
    'platform governance',
    'platform governance migration description is parsed'
);
like(
    $platform_governance_sql,
    qr/CREATE [ ] SCHEMA [ ] IF [ ] NOT [ ] EXISTS [ ] security/msx,
    'platform governance migration declares security schema'
);
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] command_log/msx,
    'platform governance migration creates command log'
);
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] role_binding_events/msx,
    'platform governance migration creates role binding event ledger'
);
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] permission_grants/msx,
    'platform governance migration creates permission grant ledger'
);
like(
    $platform_governance_sql,
qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] permission_revocations/msx,
    'platform governance migration creates permission revocation ledger'
);
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] effective_permissions/msx,
    'platform governance migration creates effective permissions projection'
);
like( $platform_governance_sql, qr/valid_from/msx,
    'platform governance migration supports temporal authorization' );
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] visibility_events/msx,
    'platform governance migration creates visibility ledger'
);
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] deletion_requests/msx,
    'platform governance migration creates deletion request ledger'
);
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] erasure_jobs/msx,
    'platform governance migration creates erasure jobs'
);
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] retention_holds/msx,
    'platform governance migration creates retention holds'
);
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] audit_checkpoints/msx,
    'platform governance migration creates audit checkpoints'
);
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] projection_offsets/msx,
    'platform governance migration tracks projection lag'
);
like(
    $platform_governance_sql,
qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] projection_generations/msx,
    'platform governance migration supports projection rebuild generations'
);
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] partition_registry/msx,
    'platform governance migration creates partition registry'
);
like( $platform_governance_sql, qr/next_attempt_at/msx,
    'platform governance migration materializes retry scheduling' );
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] dead_letters/msx,
    'platform governance migration creates dead letter queue'
);
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] thread_counter_shards/msx,
    'platform governance migration creates anti-hot-row counter shards'
);
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] view_count_deltas/msx,
    'platform governance migration creates write coalescing deltas'
);
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] thread_read_state/msx,
    'platform governance migration creates compressed read markers'
);
like(
    $platform_governance_sql,
qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] endpoint_query_budgets/msx,
    'platform governance migration creates endpoint query budgets'
);
my $endpoint_budget_source = $schema->source('EndpointQueryBudget');
is( $endpoint_budget_source->from,
    'endpoint_query_budgets',
    'endpoint query budget source maps governance table' );
ok(
    $endpoint_budget_source->has_column('max_queries'),
    'endpoint query budget source maps max query column'
);
like( $platform_governance_sql, qr/gpforum_web/msx,
    'platform governance migration records least-privilege DB role contracts' );
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] migration_safety/msx,
    'platform governance migration creates migration safety table'
);

my $notification_sql =
  path( $summary->[$NOTIFICATION_MIGRATION_INDEX]->{file} )->slurp;

is(
    $summary->[$NOTIFICATION_MIGRATION_INDEX]->{description},
    'notifications subscriptions',
    'notifications migration description is parsed'
);
like(
    $notification_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] subscriptions/msx,
    'notifications migration creates subscriptions table'
);
like(
    $notification_sql,
    qr/notification_preferences/msx,
    'notifications migration creates notification preferences table'
);

my $attachment_sql =
  path( $summary->[$ATTACHMENT_MIGRATION_INDEX]->{file} )->slurp;

is( $summary->[$ATTACHMENT_MIGRATION_INDEX]->{description},
    'attachments', 'attachments migration description is parsed' );
like(
    $attachment_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] attachments/msx,
    'attachments migration creates attachments table'
);
like( $attachment_sql, qr/attachment_links/msx,
    'attachments migration creates attachment links table' );
like( $attachment_sql, qr/attachment_variants/msx,
    'attachments migration creates attachment variants table' );

my $advanced_community_sql =
  path( $summary->[$ADVANCED_COMMUNITY_INDEX]->{file} )->slurp;

is(
    $summary->[$ADVANCED_COMMUNITY_INDEX]->{description},
    'advanced community',
    'advanced community migration description is parsed'
);
like(
    $advanced_community_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] bookmarks/msx,
    'advanced community migration creates bookmarks table'
);
like(
    $advanced_community_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] mentions/msx,
    'advanced community migration creates mentions table'
);
like(
    $advanced_community_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] reputation_events/msx,
    'advanced community migration creates reputation events table'
);
like(
    $advanced_community_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] trust_score_snapshots/msx,
    'advanced community migration creates trust score snapshots table'
);
like(
    $advanced_community_sql,
    qr/idx_user_feed_items_ranked/msx,
    'advanced community migration indexes ranked feed projection'
);

my $moderation_review_sql =
  path( $summary->[$MODERATION_REVIEW_INDEX]->{file} )->slurp;

is(
    $summary->[$MODERATION_REVIEW_INDEX]->{description},
    'moderation review',
    'moderation review migration description is parsed'
);
like(
    $moderation_review_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] reports/msx,
    'moderation review migration creates reports table'
);
like(
    $moderation_review_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] moderation_actions/msx,
    'moderation review migration creates moderation actions table'
);
like(
    $moderation_review_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] suspensions/msx,
    'moderation review migration creates suspensions table'
);
like( $moderation_review_sql, qr/idx_reports_queue/msx,
    'moderation review migration indexes report queue' );

my $admin_authorization_sql =
  path( $summary->[$ADMIN_AUTHORIZATION_INDEX]->{file} )->slurp;

is(
    $summary->[$ADMIN_AUTHORIZATION_INDEX]->{description},
    'admin authorization',
    'admin authorization migration description is parsed'
);
like(
    $admin_authorization_sql,
    qr/ALTER [ ] TABLE [ ] role_bindings/msx,
    'admin authorization migration extends role bindings'
);
like( $admin_authorization_sql, qr/created_by_user_id/msx,
    'admin authorization migration records role binding creator' );
my $admin_role_audit_table = qr/admin_role_audit_projection/msx;
like( $admin_authorization_sql, $admin_role_audit_table,
    'admin authorization migration creates role audit projection' );
like(
    $admin_authorization_sql,
    qr/idx_admin_role_audit_projection_actor/msx,
    'admin authorization migration indexes role audit projection'
);

my $import_export_sql =
  path( $summary->[$IMPORT_EXPORT_INDEX]->{file} )->slurp;

is(
    $summary->[$IMPORT_EXPORT_INDEX]->{description},
    'import export',
    'import export migration description is parsed'
);
like(
    $import_export_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] import_jobs/msx,
    'import export migration creates import jobs table'
);
like(
    $import_export_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] import_failures/msx,
    'import export migration creates import failures table'
);
like(
    $import_export_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] legacy_id_map/msx,
    'import export migration creates legacy id map table'
);
like(
    $import_export_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] export_requests/msx,
    'import export migration creates export requests table'
);

my $plugins_sql = path( $summary->[$PLUGINS_INDEX]->{file} )->slurp;

is( $summary->[$PLUGINS_INDEX]->{description},
    'plugins', 'plugins migration description is parsed' );
like(
    $plugins_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] plugins/msx,
    'plugins migration creates plugins table'
);
like(
    $plugins_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] plugin_hooks/msx,
    'plugins migration creates plugin hooks table'
);
like(
    $plugins_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] plugin_failures/msx,
    'plugins migration creates plugin failures table'
);
like(
    $plugins_sql,
    qr/idx_plugin_hooks_dispatch/msx,
    'plugins migration indexes hook dispatch path'
);

my $personal_feed_sql = path( $summary->[$PERSONAL_FEED_INDEX]->{file} )->slurp;

is(
    $summary->[$PERSONAL_FEED_INDEX]->{description},
    'personal feed indexes',
    'personal feed index migration description is parsed'
);
like(
    $personal_feed_sql,
    qr/idx_user_feed_items_user_created/msx,
    'personal feed migration indexes feed keyset order'
);
like( $personal_feed_sql, qr/INCLUDE/msx,
    'personal feed migration covers projection metadata' );

my $public_profile_sql =
  path( $summary->[$PUBLIC_PROFILE_INDEX]->{file} )->slurp;

is(
    $summary->[$PUBLIC_PROFILE_INDEX]->{description},
    'public profile indexes',
    'public profile index migration description is parsed'
);
like(
    $public_profile_sql,
    qr/idx_threads_author_public_activity/msx,
    'public profile migration indexes author activity'
);
like(
    $public_profile_sql,
    qr/WHERE [ ] deleted_at [ ] IS [ ] NULL/msx,
    'public profile migration uses a partial public-thread index'
);

my $hot_path_sql = path( $summary->[$HOT_PATH_INDEX]->{file} )->slurp;

is(
    $summary->[$HOT_PATH_INDEX]->{description},
    'hot path indexes',
    'hot path index migration description is parsed'
);
like(
    $hot_path_sql,
    qr/idx_threads_public_activity/msx,
    'hot path migration indexes public latest threads'
);
like(
    $hot_path_sql,
    qr/idx_threads_category_activity_visible_locked/msx,
    'hot path migration indexes category thread keyset order'
);
like(
    $hot_path_sql,
    qr/idx_posts_visible_thread_position/msx,
    'hot path migration indexes visible post keyset order'
);
like(
    $hot_path_sql,
    qr/moderation_state [ ] IN [ ] [(] 'visible', [ ] 'locked' [)]/msx,
    'hot path migration keeps locked readable threads in partial index'
);
like(
    $hot_path_sql,
qr/ON [ ] posts [ ] [(] thread_id, [ ] position [ ] ASC, [ ] post_id [ ] ASC [)]/msx,
    'hot path migration matches post reader ordering'
);
like(
    $hot_path_sql,
    qr/INCLUDE [ ] [(] category_id, [ ] author_user_id, [ ] title/msx,
    'hot path migration covers latest thread list metadata'
);
like(
    $hot_path_sql,
    qr/WHERE [ ] deleted_at [ ] IS [ ] NULL/msx,
    'hot path migration keeps indexes partial on live rows'
);

my $security_abuse_sql =
  path( $summary->[$SECURITY_ABUSE_INDEX]->{file} )->slurp;

is(
    $summary->[$SECURITY_ABUSE_INDEX]->{description},
    'security abuse hardening',
    'security abuse hardening migration description is parsed'
);
like(
    $security_abuse_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] rate_limit_buckets/msx,
    'security abuse migration creates PostgreSQL rate limit buckets'
);

my $search_product_sql =
  path( $summary->[$SEARCH_PRODUCT_INDEX]->{file} )->slurp;

is(
    $summary->[$SEARCH_PRODUCT_INDEX]->{description},
    'search product hardening',
    'search product migration description is parsed'
);
like(
    $search_product_sql,
    qr/ADD [ ] COLUMN [ ] IF [ ] NOT [ ] EXISTS [ ] category_id/msx,
    'search product migration adds category filter column'
);
like(
    $search_product_sql,
    qr/idx_search_documents_public_filter_rank/msx,
    'search product migration indexes filtered ranked search'
);

my $user_locale_sql = path( $summary->[$USER_LOCALE_INDEX]->{file} )->slurp;

is(
    $summary->[$USER_LOCALE_INDEX]->{description},
    'user locale preference',
    'user locale migration description is parsed'
);
like(
    $user_locale_sql,
    qr/ADD [ ] COLUMN [ ] IF [ ] NOT [ ] EXISTS [ ] preferred_locale/msx,
    'user locale migration adds preferred locale column'
);

my $user_theme_sql = path( $summary->[$USER_THEME_INDEX]->{file} )->slurp;

is(
    $summary->[$USER_THEME_INDEX]->{description},
    'user theme preference',
    'user theme migration description is parsed'
);
like(
    $user_theme_sql,
    qr/ADD [ ] COLUMN [ ] IF [ ] NOT [ ] EXISTS [ ] preferred_theme/msx,
    'user theme migration adds preferred theme column'
);
like(
    $user_theme_sql,
    qr/users_preferred_theme_check/msx,
    'user theme migration constrains supported theme names'
);

my $outbox_reliability_sql =
  path( $summary->[$OUTBOX_RELIABILITY_INDEX]->{file} )->slurp;

is(
    $summary->[$OUTBOX_RELIABILITY_INDEX]->{description},
    'outbox delivery reliability',
    'outbox reliability migration description is parsed'
);
like(
    $outbox_reliability_sql,
    qr/ADD [ ] COLUMN [ ] IF [ ] NOT [ ] EXISTS [ ] failure_type/msx,
    'outbox reliability migration adds failure type classification'
);

my $privacy_idempotency_sql =
  path( $summary->[$PRIVACY_IDEMPOTENCY_INDEX]->{file} )->slurp;

is(
    $summary->[$PRIVACY_IDEMPOTENCY_INDEX]->{description},
    'privacy erasure job idempotency',
    'privacy erasure job idempotency migration description is parsed'
);
like(
    $privacy_idempotency_sql,
    qr/idx_erasure_jobs_request_unique/msx,
    'privacy idempotency migration enforces one erasure job per request'
);

my $identity_lifecycle_sql =
  path( $summary->[$IDENTITY_LIFECYCLE_INDEX]->{file} )->slurp;

is(
    $summary->[$IDENTITY_LIFECYCLE_INDEX]->{description},
    'identity lifecycle tokens',
    'identity lifecycle migration description is parsed'
);
like(
    $identity_lifecycle_sql,
    qr/identity_tokens_hash_key/msx,
    'identity lifecycle migration enforces unique token hashes'
);

my $concurrency_sql =
  path( $summary->[$CONCURRENCY_UNIQUENESS_INDEX]->{file} )->slurp;

is(
    $summary->[$CONCURRENCY_UNIQUENESS_INDEX]->{description},
    'concurrency uniqueness',
    'concurrency uniqueness migration description is parsed'
);
like(
    $concurrency_sql,
    qr/idx_reports_reporter_target_open_unique/msx,
    'concurrency migration enforces unique open reports'
);
like(
    $concurrency_sql,
    qr/idx_moderation_actions_command_id/msx,
    'concurrency migration enforces unique moderation command ids'
);

my $migration_schema = GPForum::Test::MigrationSchema->new;
my $runner           = GPForum::Migration::Runner->new(
    schema     => $migration_schema,
    applied_by => 'test-runner',
);
my $pending = $runner->pending;

is( scalar @{$pending},
    $EXPECTED_MIGRATIONS, 'runner sees all migrations pending on empty DB' );

my $applied = $runner->apply_pending;
my $dbh     = $migration_schema->storage->dbh;

is( scalar @{$applied},
    $EXPECTED_MIGRATIONS, 'runner applies all pending migrations' );
is( scalar @{ $dbh->executed },
    $EXPECTED_RUNNER_EXECUTIONS,
    'runner executes migration SQL plus tracking inserts' );
like(
    $dbh->executed->[0]->{statement},
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] schema_versions/msx,
    'runner executes first migration SQL'
);
like(
    $dbh->executed->[1]->{statement},
    qr/INSERT [ ] INTO [ ] schema_versions/msx,
    'runner records schema version after migration'
);
is( $dbh->executed->[1]->{bind}->[0],
    '001', 'runner records first migration version' );
like(
    $applied->[0]->{checksum},
    qr/\A [[:xdigit:]]{64} \z/msx,
    'runner reports SHA-256 migration checksum'
);
like(
    $dbh->executed->[-1]->{statement},
    qr/INSERT [ ] INTO [ ] migration_safety/msx,
    'runner records migration safety metadata once available'
);
is( $dbh->executed->[-1]->{bind}->[2],
    'test-runner', 'runner records applied-by identity' );

throws_ok(
    sub {
        GPForum::Migration::Plan->new( directory => 'missing-migrations' )
          ->files;
    },
    qr/\A migration [ ] directory [ ] not [ ] found/msx,
    'missing migration directory fails clearly',
);

is_deeply( [ _json_columns_without_codec($schema) ],
    [], 'every json/jsonb column serializes Perl structures' );

sub _json_columns_without_codec {
    my ($schema_class) = @_;

    my @missing;
    for my $moniker ( sort $schema_class->sources ) {
        my $result_source = $schema_class->source($moniker);
        push @missing, map { "$moniker.$_" }
          grep { _needs_json_codec( $result_source->column_info($_) ) }
          $result_source->columns;
    }

    return @missing;
}

sub _needs_json_codec {
    my ($column_info) = @_;

    my $data_type = lc( $column_info->{data_type} || q{} );
    if ( $data_type ne 'json' && $data_type ne 'jsonb' ) {
        return 0;
    }

    return exists $column_info->{_inflate_info} ? 0 : 1;
}

1;
