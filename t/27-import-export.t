package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Portability::ExportBundleBuilder;
use GPForum::Service::Portability::ImportJobStore;
use GPForum::Service::Portability::ImportManifestValidator;
use GPForum::Service::Portability::LegacyIdMapper;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS          => 50;
const my $FIRST_ROW_INDEX         => 0;
const my $ONE_CREATED_ROW         => 1;
const my $TWO_CREATED_ROWS        => 2;
const my $TWO_POSTS               => 2;
const my $ONE_ATTACHMENT          => 1;
const my $ONE_NOTIFICATION        => 1;
const my $ONE_SUBSCRIPTION        => 1;
const my $ONE_PREFERENCE          => 1;
const my $EXPECTED_MANIFEST_KEYS  => 4;
const my $EXPECTED_PROGRESS_TOTAL => 4;
const my $EXPECTED_PROGRESS_DONE  => 2;

plan tests => $EXPECTED_TESTS;

my $import_jobs     = GPForum::Test::ModerationResultSet->new;
my $import_failures = GPForum::Test::ModerationResultSet->new;
my $legacy_map      = GPForum::Test::ModerationResultSet->new;
my $export_requests = GPForum::Test::ModerationResultSet->new;
my $event_log       = GPForum::Test::ModerationResultSet->new;
my $outbox_messages = GPForum::Test::ModerationResultSet->new;
my $audit_log       = GPForum::Test::ModerationResultSet->new;
my $schema          = GPForum::Test::ModerationSchema->new(
    resultsets => {
        AuditLog      => $audit_log,
        EventLog      => $event_log,
        ImportJob     => $import_jobs,
        ImportFailure => $import_failures,
        LegacyIdMap   => $legacy_map,
        OutboxMessage => $outbox_messages,
        ExportRequest => $export_requests,
    },
);

my $clock = GPForum::Test::FixedClock->new;
my $ids   = GPForum::Test::Id->new;

my $validator = GPForum::Service::Portability::ImportManifestValidator->new;
my $invalid   = $validator->validate(
    {
        source_system => 'legacy-forum',
        adapter_name  => 'legacy_forum_v1',
        dry_run       => 1,
        records       => { users => 1, categories => 1 },
    }
);

ok( !$invalid->{ok}, 'manifest validation rejects missing required fields' );
like( $invalid->{errors}{source_version},
    qr/required/msx, 'manifest validation reports missing source version' );
like( $invalid->{errors}{'records.threads'},
    qr/non-negative/msx, 'manifest validation reports missing thread count' );
like( $invalid->{errors}{'records.posts'},
    qr/non-negative/msx, 'manifest validation reports missing post count' );

my $manifest = {
    source_system  => 'legacy-forum',
    source_version => '1.4',
    adapter_name   => 'legacy_forum_v1',
    dry_run        => 1,
    records        => {
        users      => 2,
        categories => 1,
        threads    => 1,
        posts      => 4,
    },
};
my $valid = $validator->validate($manifest);
ok( $valid->{ok}, 'complete manifest validates' );
is( scalar keys %{ $manifest->{records} },
    $EXPECTED_MANIFEST_KEYS, 'manifest declares canonical record counts' );

my $job_store = GPForum::Service::Portability::ImportJobStore->new(
    schema     => $schema,
    clock      => $clock,
    id_service => $ids,
);
my $created = $job_store->create_job(
    {
        actor_user_id => 'user-1',
        manifest      => $manifest,
    }
);

ok( $created->{ok}, 'import job creation succeeds' );
is( $created->{job}{import_job_id},
    'generated-1', 'import job id is generated' );
is( $created->{job}{source_system},
    'legacy-forum', 'import stores source system' );
is( $created->{job}{adapter_name}, 'legacy_forum_v1', 'import stores adapter' );
is( $created->{job}{dry_run},      1,        'import stores dry-run flag' );
is( $created->{job}{created_by},   'user-1', 'import stores actor' );
is( $created->{job}{created_at},
    '2026-05-23T12:00:00Z', 'import stores created timestamp' );
is( scalar @{ $import_jobs->created },
    $ONE_CREATED_ROW, 'import job row is inserted' );

my $rejected = $job_store->create_job( { actor_user_id => 'user-1' } );
ok( !$rejected->{ok}, 'import job store rejects invalid manifests' );
like( $rejected->{errors}{source_system},
    qr/required/msx, 'import job store returns manifest errors' );

my $progress = $job_store->update_progress(
    'generated-1',
    {
        total_records     => $EXPECTED_PROGRESS_TOTAL,
        completed_records => $EXPECTED_PROGRESS_DONE,
    }
);
is( $progress->{import_job_id},
    'generated-1', 'progress update returns job id' );
is(
    $import_jobs->find('generated-1')->get_column('progress')
      ->{completed_records},
    $EXPECTED_PROGRESS_DONE, 'progress is stored on the import job row'
);

my $failure = $job_store->record_failure(
    {
        import_job_id      => 'generated-1',
        source_record_type => 'post',
        source_record_id   => 'legacy-post-9',
        error_code         => 'invalid_html',
        error_message      => 'HTML sanitizer rejected input',
        payload            => { title => 'Bad post' },
    }
);
is( $failure->{import_failure_id},  'generated-2', 'failure id is generated' );
is( $failure->{source_record_type}, 'post', 'failure stores source type' );
is( $failure->{error_code}, 'invalid_html', 'failure stores error code' );
is( scalar @{ $import_failures->created },
    $ONE_CREATED_ROW, 'failure row is inserted' );

my $mapper = GPForum::Service::Portability::LegacyIdMapper->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);
my $mapping = $mapper->map_identifier(
    {
        import_job_id => 'generated-1',
        legacy_type   => 'thread',
        legacy_id     => 'old-42',
        native_type   => 'thread',
        native_id     => '00000000-0000-7000-8000-000000000042',
        canonical_url => '/t/welcome',
        visibility    => 'public',
    }
);
is( $mapping->{legacy_id_map_id},
    'generated-1', 'legacy mapping id is generated' );
is( $mapping->{legacy_id}, 'old-42', 'legacy mapping stores source id' );
is(
    scalar @{ $legacy_map->created },
    $ONE_CREATED_ROW,
    'legacy mapping row is inserted'
);
is(
    $mapper->find_native( 'thread', 'old-42' )->get_column('native_id'),
    '00000000-0000-7000-8000-000000000042',
    'legacy lookup returns native target'
);

my $export_builder = GPForum::Service::Portability::ExportBundleBuilder->new(
    schema     => $schema,
    clock      => $clock,
    id_service => GPForum::Test::Id->new,
);
my $request = $export_builder->create_request(
    {
        requester_user_id => 'user-1',
        subject_user_id   => 'user-2',
        export_type       => 'user_data',
    }
);
is( $request->{export_request_id},
    'generated-1', 'export request id is generated' );
is( $request->{format}, 'json',    'export defaults to json' );
is( $request->{status}, 'pending', 'export starts pending' );
is( scalar @{ $export_requests->created },
    $ONE_CREATED_ROW, 'export request row is inserted' );
is( scalar @{ $event_log->created },
    $ONE_CREATED_ROW, 'export request emits privacy event' );
is( scalar @{ $outbox_messages->created },
    $ONE_CREATED_ROW, 'export request queues outbox message' );
is( scalar @{ $audit_log->created },
    $ONE_CREATED_ROW, 'export request writes audit row' );

my $bundle = $export_builder->build_user_bundle(
    'user-2',
    {
        profile       => { username => 'giacomo' },
        posts         => [ { post_id         => 1 }, { post_id => 2 } ],
        attachments   => [ { attachment_id   => 1 } ],
        notifications => [ { notification_id => 1 } ],
        subscriptions => [ { thread_id       => 1 } ],
        preferences   => [ { channel         => 'email' } ],
        audit_log     => [ { secret          => 'must-not-leak' } ],
    }
);
is( $bundle->{subject_user_id},   'user-2',  'bundle stores subject' );
is( $bundle->{profile}{username}, 'giacomo', 'bundle includes profile part' );
ok( !exists $bundle->{audit_log}, 'bundle excludes privileged audit details' );

my $safe_manifest = $export_builder->safe_manifest($bundle);
is( $safe_manifest->{counts}{posts}, $TWO_POSTS, 'manifest counts posts' );
is( $safe_manifest->{counts}{attachments},
    $ONE_ATTACHMENT, 'manifest counts attachments' );
is( $safe_manifest->{counts}{notifications},
    $ONE_NOTIFICATION, 'manifest counts notifications' );
is( $safe_manifest->{counts}{subscriptions},
    $ONE_SUBSCRIPTION, 'manifest counts subscriptions' );
is( $safe_manifest->{counts}{preferences},
    $ONE_PREFERENCE, 'manifest counts preferences' );
ok( !exists $safe_manifest->{audit_log}, 'safe manifest excludes audit data' );
ok(
    !exists $safe_manifest->{moderation_actions},
    'safe manifest excludes moderation data'
);

my $completed_export = $export_builder->complete_user_export(
    'generated-1',
    {
        profile       => { username => 'giacomo' },
        posts         => [ { post_id         => 1 }, { post_id => 2 } ],
        attachments   => [ { attachment_id   => 1 } ],
        notifications => [ { notification_id => 1 } ],
        subscriptions => [ { thread_id       => 1 } ],
        preferences   => [ { channel         => 'email' } ],
    }
);
is( $completed_export->{status},
    'completed', 'export completion updates request status' );
is( $export_requests->find('generated-1')->get_column('status'),
    'completed', 'export completion persists status' );
is( $completed_export->{manifest}{counts}{notifications},
    $ONE_NOTIFICATION, 'completed export stores safe notification count' );
is( scalar @{ $event_log->created },
    $TWO_CREATED_ROWS, 'export completion emits second privacy event' );
is( scalar @{ $outbox_messages->created },
    $TWO_CREATED_ROWS, 'export completion queues second outbox message' );
my $completed_export_again = $export_builder->complete_user_export(
    'generated-1',
    {
        profile => { username => 'changed' },
    }
);
is( $completed_export_again->{status},
    'completed', 'export completion is idempotent' );
is( scalar @{ $audit_log->created },
    $TWO_CREATED_ROWS,
    'idempotent export completion avoids duplicate audit rows' );

1;
