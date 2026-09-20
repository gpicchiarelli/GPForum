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

const my $EXPECTED_TESTS          => 114;
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

my $import_jobs = GPForum::Test::ModerationResultSet->new;
my $import_failures =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $legacy_map = GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $export_requests =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $users       = GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $posts       = GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $post_bodies = GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $attachments = GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $inbox       = GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $subscriptions =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $preferences = GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $event_log   = GPForum::Test::ModerationResultSet->new;
my $outbox_messages = GPForum::Test::ModerationResultSet->new;
my $audit_log       = GPForum::Test::ModerationResultSet->new;
my $schema          = GPForum::Test::ModerationSchema->new(
    resultsets => {
        Attachment             => $attachments,
        AuditLog               => $audit_log,
        EventLog               => $event_log,
        ExportRequest          => $export_requests,
        ImportFailure          => $import_failures,
        ImportJob              => $import_jobs,
        LegacyIdMap            => $legacy_map,
        NotificationInbox      => $inbox,
        NotificationPreference => $preferences,
        OutboxMessage          => $outbox_messages,
        Post                   => $posts,
        PostBody               => $post_bodies,
        Subscription           => $subscriptions,
        User                   => $users,
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

my $id_jobs = GPForum::Test::ModerationResultSet->new;
$id_jobs->create(
    {
        adapter_name  => 'other-adapter',
        import_job_id => 'generated-1',
        source_system => 'other-system',
    }
);
my $id_store = GPForum::Service::Portability::ImportJobStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => { ImportJob => $id_jobs },
    ),
);
my $id_created = $id_store->create_job(
    {
        actor_user_id => 'user-1',
        manifest      => $manifest,
    }
);
ok( $id_created->{ok}, 'unique import job id collision remints and creates' );
ok( !$id_created->{skipped},
    'unique import job id collision does not reuse another job' );
is( $id_created->{job}{import_job_id},
    'generated-2', 'unique import job id collision remints the id' );
is( $id_created->{job}{source_system},
    'legacy-forum', 'unique import job id collision keeps this job source' );

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
my $same_progress = $job_store->update_progress(
    'generated-1',
    {
        completed_records => $EXPECTED_PROGRESS_DONE,
        total_records     => $EXPECTED_PROGRESS_TOTAL,
    }
);
ok( $same_progress->{skipped},
    'unchanged import progress skip does not rewrite the row' );
is(
    $import_jobs->find('generated-1')->get_column('progress')
      ->{completed_records},
    $EXPECTED_PROGRESS_DONE,
    'unchanged import progress keeps the stored counters'
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

my $same_failure = $job_store->record_failure(
    {
        error_code         => 'invalid_html',
        error_message      => 'HTML sanitizer rejected input again',
        import_job_id      => 'generated-1',
        payload            => { title => 'Bad post retry' },
        source_record_id   => 'legacy-post-9',
        source_record_type => 'post',
    }
);
ok( $same_failure->{skipped},
    'already-recorded import failure skip does not insert a second row' );
is( $same_failure->{import_failure_id},
    'generated-2', 'already-recorded import failure keeps the original id' );
is( scalar @{ $import_failures->created },
    $ONE_CREATED_ROW,
    'already-recorded import failure does not insert a second row' );

$import_failures->skip_search(1);
my $raced_failure = $job_store->record_failure(
    {
        error_code         => 'invalid_html',
        error_message      => 'HTML sanitizer rejected input race',
        import_job_id      => 'generated-1',
        payload            => { title => 'Bad post race' },
        source_record_id   => 'legacy-post-9',
        source_record_type => 'post',
    }
);
ok( $raced_failure->{skipped},
    'unique import failure race reuses the source row' );

my $id_failures = GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$id_failures->create(
    {
        error_code         => 'other',
        error_message      => 'other failure',
        import_failure_id  => 'generated-1',
        import_job_id      => 'other-job',
        source_record_id   => 'legacy-other',
        source_record_type => 'thread',
    }
);
my $fail_id_store = GPForum::Service::Portability::ImportJobStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => { ImportFailure => $id_failures },
    ),
);
my $id_failure = $fail_id_store->record_failure(
    {
        error_code         => 'invalid_html',
        error_message      => 'HTML sanitizer rejected input',
        import_job_id      => 'generated-1',
        source_record_id   => 'legacy-post-pk',
        source_record_type => 'post',
    }
);
ok( !$id_failure->{skipped},
    'unique import failure id collision remints and records' );
is( $id_failure->{import_failure_id},
    'generated-2', 'unique import failure id collision remints the id' );
is( $id_failure->{source_record_id},
    'legacy-post-pk',
    'unique import failure id collision keeps this source record' );
is( $id_failure->{import_job_id},
    'generated-1', 'unique import failure id collision keeps this job' );

my $failure_leftover_rows =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$failure_leftover_rows->create(
    {
        error_code         => 'invalid_html',
        error_message      => 'HTML sanitizer rejected input',
        import_failure_id  => 'generated-1',
        import_job_id      => 'leftover-job',
        source_record_id   => 'legacy-leftover',
        source_record_type => 'post',
    }
);
$failure_leftover_rows->skip_search(1);
my $failure_leftover_store = GPForum::Service::Portability::ImportJobStore->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => { ImportFailure => $failure_leftover_rows },
    ),
);
my $failure_leftover = $failure_leftover_store->record_failure(
    {
        error_code         => 'invalid_html',
        error_message      => 'HTML sanitizer rejected input',
        import_job_id      => 'leftover-job',
        source_record_id   => 'legacy-leftover',
        source_record_type => 'post',
    }
);
ok( $failure_leftover->{skipped},
    'leftover import failure id race reuses this failure' );
is( $failure_leftover->{import_failure_id},
    'generated-1', 'leftover import failure id race keeps this failure' );
is( $failure_leftover->{source_record_id},
    'legacy-leftover',
    'leftover import failure id race keeps this source record' );
is( scalar @{ $failure_leftover_rows->created },
    $ONE_CREATED_ROW,
    'leftover import failure id race does not insert a second row' );

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
my $mapped_again = $mapper->map_identifier(
    {
        canonical_url => '/t/welcome-again',
        import_job_id => 'generated-1',
        legacy_id     => 'old-42',
        legacy_type   => 'thread',
        native_id     => '00000000-0000-7000-8000-000000000099',
        native_type   => 'thread',
        visibility    => 'public',
    }
);
ok( $mapped_again->{skipped},
    'already-mapped legacy id skip does not insert a second row' );
is( $mapped_again->{legacy_id_map_id},
    'generated-1', 'already-mapped legacy id keeps the original map id' );
is(
    $mapped_again->{native_id},
    '00000000-0000-7000-8000-000000000042',
    'already-mapped legacy id keeps the original native id'
);
is( scalar @{ $legacy_map->created },
    $ONE_CREATED_ROW, 'already-mapped legacy id does not insert a second row' );

$legacy_map->skip_search(1);
my $raced_mapping = $mapper->map_identifier(
    {
        canonical_url => '/t/welcome-race',
        import_job_id => 'generated-1',
        legacy_id     => 'old-42',
        legacy_type   => 'thread',
        native_id     => '00000000-0000-7000-8000-000000000099',
        native_type   => 'thread',
        visibility    => 'public',
    }
);
ok( $raced_mapping->{skipped}, 'unique legacy map race reuses the source key' );
is( $raced_mapping->{legacy_id_map_id},
    'generated-1', 'unique legacy map race returns the original map id' );
is( scalar @{ $legacy_map->created },
    $ONE_CREATED_ROW, 'unique legacy map race does not insert a second row' );

my $map_pk_maps = GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$map_pk_maps->create(
    {
        import_job_id    => 'other-job',
        legacy_id        => 'old-other',
        legacy_id_map_id => 'generated-1',
        legacy_type      => 'post',
        native_id        => '00000000-0000-7000-8000-000000000001',
        native_type      => 'post',
        visibility       => 'public',
    }
);
my $map_pk_mapper = GPForum::Service::Portability::LegacyIdMapper->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => { LegacyIdMap => $map_pk_maps },
    ),
);
my $map_pk = $map_pk_mapper->map_identifier(
    {
        canonical_url => '/t/welcome',
        import_job_id => 'generated-1',
        legacy_id     => 'old-42',
        legacy_type   => 'thread',
        native_id     => '00000000-0000-7000-8000-000000000042',
        native_type   => 'thread',
        visibility    => 'public',
    }
);
ok( !$map_pk->{skipped}, 'unique legacy map id collision remints and maps' );
is( $map_pk->{legacy_id_map_id},
    'generated-2', 'unique legacy map id collision remints the id' );
is( $map_pk->{legacy_id}, 'old-42',
    'unique legacy map id collision keeps this legacy id' );
is( $map_pk->{legacy_type},
    'thread', 'unique legacy map id collision keeps this legacy type' );

my $map_leftover_maps =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$map_leftover_maps->create(
    {
        import_job_id    => 'leftover-job',
        legacy_id        => 'old-leftover',
        legacy_id_map_id => 'generated-1',
        legacy_type      => 'thread',
        native_id        => '00000000-0000-7000-8000-000000000042',
        native_type      => 'thread',
        visibility       => 'public',
    }
);
$map_leftover_maps->skip_search(1);
my $map_leftover_mapper = GPForum::Service::Portability::LegacyIdMapper->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => { LegacyIdMap => $map_leftover_maps },
    ),
);
my $map_leftover = $map_leftover_mapper->map_identifier(
    {
        canonical_url => '/t/welcome',
        import_job_id => 'leftover-job',
        legacy_id     => 'old-leftover',
        legacy_type   => 'thread',
        native_id     => '00000000-0000-7000-8000-000000000042',
        native_type   => 'thread',
        visibility    => 'public',
    }
);
ok( $map_leftover->{skipped},
    'leftover legacy map id race reuses this mapping' );
is( $map_leftover->{legacy_id_map_id},
    'generated-1', 'leftover legacy map id race keeps this mapping' );
is( $map_leftover->{legacy_id},
    'old-leftover', 'leftover legacy map id race keeps this legacy id' );
is( scalar @{ $map_leftover_maps->created },
    $ONE_CREATED_ROW,
    'leftover legacy map id race does not insert a second mapping' );

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

my $request_again = $export_builder->create_request(
    {
        requester_user_id => 'user-1',
        subject_user_id   => 'user-2',
        export_type       => 'user_data',
    }
);
is( $request_again->{export_request_id},
    'generated-1', 'retry reuses the pending export request' );
is( scalar @{ $export_requests->created },
    $ONE_CREATED_ROW, 'retry does not insert a second export request' );
is( scalar @{ $event_log->created },
    $ONE_CREATED_ROW, 'retry does not emit a second export event' );

$export_requests->skip_search(1);
my $raced_export = $export_builder->create_request(
    {
        requester_user_id => 'user-1',
        subject_user_id   => 'user-2',
        export_type       => 'user_data',
    }
);
is( $raced_export->{export_request_id},
    'generated-1', 'unique race reuses the pending export request' );
is( scalar @{ $export_requests->created },
    $ONE_CREATED_ROW, 'unique race does not insert a second export request' );

my $export_pk_rows =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$export_pk_rows->create(
    {
        export_request_id => 'generated-1',
        export_type       => 'user_data',
        format            => 'json',
        requester_user_id => 'other-user',
        status            => 'pending',
        subject_user_id   => 'other-subject',
    }
);
my $export_pk_events = GPForum::Test::ModerationResultSet->new;
my $export_pk_outbox = GPForum::Test::ModerationResultSet->new;
my $export_pk_audits = GPForum::Test::ModerationResultSet->new;
my $export_pk_store  = GPForum::Service::Portability::ExportBundleBuilder->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog      => $export_pk_audits,
            EventLog      => $export_pk_events,
            ExportRequest => $export_pk_rows,
            OutboxMessage => $export_pk_outbox,
        },
    ),
);
my $export_pk = $export_pk_store->create_request(
    {
        export_type       => 'user_data',
        requester_user_id => 'user-1',
        subject_user_id   => 'user-2',
    }
);
is( $export_pk->{export_request_id},
    'generated-2', 'unique export id collision remints the id' );
is( $export_pk->{requester_user_id},
    'user-1', 'unique export id collision keeps this requester' );
is( $export_pk->{subject_user_id},
    'user-2', 'unique export id collision keeps this subject' );
is( scalar @{ $export_pk_rows->created },
    $TWO_CREATED_ROWS, 'unique export id collision inserts this request' );

my $export_leftover_rows =
  GPForum::Test::ModerationResultSet->new( filter_search => 1 );
$export_leftover_rows->create(
    {
        export_request_id => 'generated-1',
        export_type       => 'user_data',
        format            => 'json',
        requester_user_id => 'user-leftover',
        status            => 'pending',
        subject_user_id   => 'user-leftover-subject',
    }
);
$export_leftover_rows->skip_search(1);
my $export_leftover_events = GPForum::Test::ModerationResultSet->new;
my $export_leftover_outbox = GPForum::Test::ModerationResultSet->new;
my $export_leftover_audits = GPForum::Test::ModerationResultSet->new;
my $export_leftover_store =
  GPForum::Service::Portability::ExportBundleBuilder->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
    schema     => GPForum::Test::ModerationSchema->new(
        resultsets => {
            AuditLog      => $export_leftover_audits,
            EventLog      => $export_leftover_events,
            ExportRequest => $export_leftover_rows,
            OutboxMessage => $export_leftover_outbox,
        },
    ),
  );
my $export_leftover = $export_leftover_store->create_request(
    {
        export_type       => 'user_data',
        requester_user_id => 'user-leftover',
        subject_user_id   => 'user-leftover-subject',
    }
);
is( $export_leftover->{export_request_id},
    'generated-1', 'leftover export id race keeps this request' );
is( $export_leftover->{requester_user_id},
    'user-leftover', 'leftover export id race keeps this requester' );
is( scalar @{ $export_leftover_rows->created },
    $ONE_CREATED_ROW,
    'leftover export id race does not insert a second request' );
is( scalar @{ $export_leftover_events->created },
    $ONE_CREATED_ROW, 'leftover export id race inserts the missing event' );
is( scalar @{ $export_leftover_outbox->created },
    $ONE_CREATED_ROW, 'leftover export id race inserts the missing outbox' );
is( scalar @{ $export_leftover_audits->created },
    $ONE_CREATED_ROW, 'leftover export id race inserts the missing audit' );

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
is( $completed_export->{manifest}{posts}[0]{post_id},
    1, 'completed export stores the supplied post rows' );
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

my $request_after_complete = $export_builder->create_request(
    {
        requester_user_id => 'user-1',
        subject_user_id   => 'user-2',
        export_type       => 'user_data',
    }
);
isnt( $request_after_complete->{export_request_id},
    'generated-1', 'a new export starts after the previous one completed' );
is( scalar @{ $export_requests->created },
    $TWO_CREATED_ROWS, 'completed export does not block a later request' );

$users->create(
    {
        created_at        => '2026-01-01T00:00:00Z',
        display_name      => 'Giacomo',
        email_normalized  => 'giacomo@example.test',
        email_verified_at => '2026-05-01T00:00:00Z',
        id                => 'user-2',
        password_hash     => 'must-not-export',
        preferred_locale  => 'it',
        preferred_theme   => 'dark',
        status            => 'active',
        username          => 'giacomo',
    }
);
$posts->create(
    {
        author_user_id   => 'user-2',
        created_at       => '2026-05-23T12:00:00Z',
        deleted_at       => undef,
        moderation_state => 'visible',
        position         => 1,
        post_id          => 'post-9',
        thread_id        => 'thread-1',
        updated_at       => '2026-05-23T12:00:00Z',
        visibility       => 'public',
    }
);
$post_bodies->create(
    {
        body_format => 'markdown',
        body_source => 'Hello from export',
        post_id     => 'post-9',
    }
);
$attachments->create(
    {
        attachment_id     => 'att-1',
        byte_size         => 12,
        checksum          => 'abc',
        created_at        => '2026-05-23T12:00:00Z',
        deleted_at        => undef,
        media_type        => 'text/plain',
        object_key        => 'secret/object',
        original_filename => 'notes.txt',
        owner_user_id     => 'user-2',
        scan_status       => 'clean',
        state             => 'ready',
        uploaded_at       => '2026-05-23T12:00:00Z',
    }
);
$inbox->create(
    {
        created_at        => '2026-05-23T12:00:00Z',
        notification_id   => 'notif-1',
        read_at           => undef,
        recipient_user_id => 'user-2',
    }
);
$subscriptions->create(
    {
        created_at      => '2026-05-23T12:00:00Z',
        muted_at        => undef,
        preference      => 'all',
        revoked_at      => undef,
        subscription_id => 'sub-1',
        target_id       => 'thread-1',
        target_type     => 'thread',
        user_id         => 'user-2',
    }
);
$preferences->create(
    {
        channel          => 'email',
        digest_frequency => 'daily',
        enabled          => 1,
        updated_at       => '2026-05-23T12:00:00Z',
        user_id          => 'user-2',
    }
);

my $stored_export = $export_builder->complete_user_export(
    $request_after_complete->{export_request_id} );
is( $stored_export->{status},
    'completed', 'storage-backed export completes without caller parts' );
is( $stored_export->{manifest}{profile}{email},
    'giacomo@example.test', 'storage-backed export includes the member email' );
is( $stored_export->{manifest}{profile}{username},
    'giacomo', 'storage-backed export includes the public profile' );
ok(
    !exists $stored_export->{manifest}{profile}{password_hash},
    'storage-backed export omits the password hash'
);
is(
    $stored_export->{manifest}{posts}[0]{body_source},
    'Hello from export',
    'storage-backed export includes post source'
);
ok(
    !exists $stored_export->{manifest}{posts}[0]{index},
    'storage-backed export does not use placeholder index rows'
);
is( $stored_export->{manifest}{attachments}[0]{original_filename},
    'notes.txt', 'storage-backed export includes attachment names' );
ok(
    !exists $stored_export->{manifest}{attachments}[0]{object_key},
    'storage-backed export omits storage object keys'
);
is( $stored_export->{manifest}{notifications}[0]{notification_id},
    'notif-1', 'storage-backed export includes inbox rows' );
is( $stored_export->{manifest}{subscriptions}[0]{target_id},
    'thread-1', 'storage-backed export includes subscriptions' );
is( $stored_export->{manifest}{preferences}[0]{channel},
    'email', 'storage-backed export includes notification preferences' );
ok( !exists $event_log->created->[-1]{payload}{manifest}{posts},
    'export completion event omits post bodies' );
ok(
    exists $event_log->created->[-1]{payload}{manifest}{counts},
    'export completion event keeps manifest counts'
);

1;
