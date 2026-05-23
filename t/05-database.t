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

const my $EXPECTED_TESTS             => 182;
const my $EXPECTED_MIGRATIONS        => 4;
const my $EXPECTED_RUNNER_EXECUTIONS => 9;
const my $FORUM_MIGRATION_INDEX      => 2;
const my $GOVERNANCE_MIGRATION_INDEX => 3;

plan tests => $EXPECTED_TESTS;

my $schema                       = GPForum::Schema->clone;
my $source                       = $schema->source('SchemaVersion');
my $event_source                 = $schema->source('EventLog');
my $audit_source                 = $schema->source('AuditLog');
my $outbox_source                = $schema->source('OutboxMessage');
my $dead_letter_source           = $schema->source('DeadLetter');
my $projection_offset_source     = $schema->source('ProjectionOffset');
my $projection_generation_source = $schema->source('ProjectionGeneration');

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

my $user_source          = $schema->source('User');
my $credential_source    = $schema->source('Credential');
my $session_source       = $schema->source('Session');
my $space_source         = $schema->source('Space');
my $category_source      = $schema->source('Category');
my $thread_source        = $schema->source('Thread');
my $post_source          = $schema->source('Post');
my $body_source          = $schema->source('PostBody');
my $revision_source      = $schema->source('PostRevision');
my $counter_source       = $schema->source('ThreadCounter');
my $counter_shard_source = $schema->source('ThreadCounterShard');
my $stat_source          = $schema->source('CategoryStat');
my $search_source        = $schema->source('SearchDocument');

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
ok(
    $user_source->has_relationship('credentials'),
    'user has credentials relationship'
);
ok( $user_source->has_relationship('sessions'),
    'user has sessions relationship' );

is( $credential_source->from, 'credentials',
    'credential source maps credentials table' );
ok(
    $credential_source->has_column('secret_hash'),
    'credential stores only secret hash'
);
ok( $credential_source->has_relationship('user'),
    'credential belongs to user' );

is( $session_source->from, 'sessions', 'session source maps sessions table' );
is_deeply( [ $session_source->primary_columns ],
    ['session_id'], 'session primary key is explicit' );
ok( $session_source->has_column('session_hash'), 'session stores token hash' );
ok( $session_source->has_column('revoked_at'), 'session supports revocation' );
ok( $session_source->has_relationship('user'), 'session belongs to user' );

is( $space_source->from, 'spaces', 'space source maps spaces table' );
is_deeply( [ $space_source->primary_columns ],
    ['space_id'], 'space primary key is explicit' );
ok(
    $space_source->has_relationship('categories'),
    'space has categories relationship'
);

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

is( scalar @{$summary}, $EXPECTED_MIGRATIONS, 'four migrations are planned' );
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
like( $platform_governance_sql, qr/gpforum_web/msx,
    'platform governance migration records least-privilege DB role contracts' );
like(
    $platform_governance_sql,
    qr/CREATE [ ] TABLE [ ] IF [ ] NOT [ ] EXISTS [ ] migration_safety/msx,
    'platform governance migration creates migration safety table'
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

1;
