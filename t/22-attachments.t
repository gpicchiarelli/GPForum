package main;

use strict;
use warnings;

use Const::Fast;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Attachment::Delivery;
use GPForum::Service::Attachment::FilesystemStorage;
use GPForum::Service::Attachment::IntentBuilder;
use GPForum::Service::Attachment::MediaProcessor;
use GPForum::Service::Attachment::Store;
use GPForum::Service::Attachment::UploadPipeline;
use GPForum::Service::Attachment::Validator;
use GPForum::Test::AttachmentResultSet;
use GPForum::Test::AttachmentSchema;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::WorkerSink;
use GPForum::Worker::Handler::AttachmentScanning;
use GPForum::Worker::Handler::MediaProcessing;

our $VERSION = '0.001';

const my $MAX_BYTES_PLUS_ONE => 25 * 1_024 * 1_024 + 1;
const my $PNG_BYTES          => "\x89PNG\x0d\x0a\x1a\x0aattachment";
const my $VALID_BYTES        => 4_096;
const my $VARIANT_BYTES      => 512;

my $validator = GPForum::Service::Attachment::Validator->new;
my $invalid   = $validator->validate_upload(
    {
        owner_user_id     => 'user-1',
        original_filename => 'shell.pl',
        media_type        => 'application/x-perl',
        byte_size         => $MAX_BYTES_PLUS_ONE,
        checksum          => 'ABC123',
    }
);

ok( !$invalid->{ok}, 'invalid upload is rejected' );
is(
    $invalid->{errors}{media_type},
    'media_type is not allowed',
    'unsafe media type is rejected'
);
is(
    $invalid->{errors}{original_filename},
    'executable uploads are not allowed',
    'executable filename is rejected'
);
is(
    $invalid->{errors}{byte_size},
    'byte_size exceeds limit',
    'oversized upload is rejected'
);

my $valid = $validator->validate_upload(
    {
        owner_user_id     => 'user-1',
        original_filename => 'photo.PNG',
        media_type        => 'IMAGE/PNG',
        byte_size         => $VALID_BYTES,
        checksum          => 'ABCDEF',
    }
);

ok( $valid->{ok}, 'valid upload is accepted' );
is( $valid->{values}{media_type}, 'image/png', 'media type is normalized' );
is( $valid->{values}{checksum},   'abcdef',    'checksum is normalized' );

my $sniffed = $validator->validate_upload(
    {
        owner_user_id     => 'user-1',
        original_filename => 'contract.bin',
        media_type        => 'image/png',
        byte_size         => length '%PDF-1.7',
        checksum          => 'def456',
        content           => '%PDF-1.7',
    }
);
ok( $sniffed->{ok}, 'server-side MIME sniff accepts valid content' );
is( $sniffed->{values}{media_type},
    'application/pdf', 'server-side MIME sniffing ignores client media type' );

my $builder = GPForum::Service::Attachment::IntentBuilder->new(
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
);
my $intent = $builder->build_intent( $valid->{values} );

is( $intent->{attachment_id}, 'generated-1', 'intent has generated id' );
is( $intent->{owner_user_id}, 'user-1',      'intent stores owner' );
is(
    $intent->{object_key},
    'attachments/user-1/generated-1',
    'intent stores object key'
);
is( $intent->{state},       'intent',  'intent starts in intent state' );
is( $intent->{scan_status}, 'pending', 'intent starts scan pending' );
is( $intent->{created_at},
    '2026-05-23T12:00:00Z', 'intent stores creation time' );

my $attachments = GPForum::Test::AttachmentResultSet->new;
my $links       = GPForum::Test::AttachmentResultSet->new;
my $variants    = GPForum::Test::AttachmentResultSet->new;
my $events      = GPForum::Test::AttachmentResultSet->new;
my $audits      = GPForum::Test::AttachmentResultSet->new;
my $outbox      = GPForum::Test::AttachmentResultSet->new;
my $posts       = GPForum::Test::AttachmentResultSet->new;
my $schema      = GPForum::Test::AttachmentSchema->new(
    resultsets => {
        Attachment        => $attachments,
        AttachmentLink    => $links,
        AttachmentVariant => $variants,
        EventLog          => $events,
        AuditLog          => $audits,
        OutboxMessage     => $outbox,
        Post              => $posts,
    },
);
$posts->create(
    {
        post_id          => 'post-1',
        author_user_id   => 'user-1',
        visibility       => 'public',
        moderation_state => 'visible',
        deleted_at       => undef,
        hidden_at        => undef,
    }
);
my $store = GPForum::Service::Attachment::Store->new(
    schema     => $schema,
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
);
my $created = $store->create_intent($intent);

ok( $created->{ok}, 'attachment intent is stored' );
is( $schema->transactions,             1, 'intent is stored in transaction' );
is( scalar @{ $attachments->created }, 1, 'attachment row is inserted' );
is( scalar @{ $events->created },      1, 'upload event is inserted' );
is( scalar @{ $audits->created },      1, 'upload audit is inserted' );
is( scalar @{ $outbox->created },      1, 'upload outbox row is inserted' );
is( $events->created->[0]{event_type},
    'attachment.uploaded', 'upload event type is recorded' );
is( $events->created->[0]{payload}{attachment_id},
    'generated-1', 'upload event payload records attachment' );
is( $outbox->created->[0]{payload}{event_type},
    'attachment.uploaded', 'outbox payload carries upload event' );
is( $outbox->created->[0]{payload}{domain_payload}{attachment_id},
    'generated-1', 'outbox payload carries domain payload' );

my $link = $store->link_attachment(
    {
        attachment_id => 'generated-1',
        target_type   => 'post',
        target_id     => 'post-1',
    }
);

is( $link->{attachment_id}, 'generated-1',
    'attachment link stores attachment' );
is( $link->{target_type},        'post', 'attachment link stores target type' );
is( scalar @{ $links->created }, 1,      'attachment link row is inserted' );

my $uploaded = $store->mark_uploaded('generated-1');
is( $uploaded->{state}, 'uploaded', 'attachment can be marked uploaded' );
is( $uploaded->{uploaded_at},
    '2026-05-23T12:00:00Z', 'uploaded timestamp is stored' );

my $clean = $store->record_scan(
    {
        attachment_id => 'generated-1',
        actor_id      => 'scanner',
        scan_status   => 'clean',
    }
);

is( $clean->{state}, 'available',   'clean scan makes attachment available' );
is( $clean->{scan_status}, 'clean', 'clean scan status is stored' );
is( $events->created->[-1]{event_type},
    'attachment.scanned', 'clean scan records scanned event' );

my $download = $store->download_for(
    {
        attachment_id  => 'generated-1',
        viewer_user_id => undef,
    }
);
ok( $download->{ok}, 'public linked clean attachment can be downloaded' );
is(
    $download->{object_key},
    'attachments/user-1/generated-1',
    'download exposes storage object key'
);

my $quarantined = $store->record_scan(
    {
        attachment_id => 'generated-1',
        actor_id      => 'scanner',
        scan_status   => 'infected',
        reason        => 'malware',
    }
);

is( $quarantined->{state},
    'quarantined', 'infected scan quarantines attachment' );
is( $quarantined->{quarantined_at},
    '2026-05-23T12:00:00Z', 'quarantine timestamp is stored' );
is( $events->created->[-1]{event_type},
    'attachment.quarantined', 'infected scan records quarantine event' );
ok(
    !$store->download_for(
        { attachment_id => 'generated-1', viewer_user_id => 'user-1' }
    )->{ok},
    'quarantined attachment is not downloadable'
);

my $variant = $store->add_variant(
    {
        attachment_id => 'generated-1',
        variant_type  => 'thumbnail',
        object_key    => 'attachments/user-1/generated-1/thumb',
        media_type    => 'image/webp',
        byte_size     => $VARIANT_BYTES,
    }
);

is( $variant->{variant_type}, 'thumbnail', 'variant stores variant type' );
is( scalar @{ $variants->created }, 1,     'variant row is inserted' );
ok(
    $store->add_variant(
        {
            attachment_id => 'generated-1',
            variant_type  => 'thumbnail',
            object_key    => 'attachments/user-1/generated-1/thumb',
            media_type    => 'image/webp',
            byte_size     => $VARIANT_BYTES,
        }
    )->{idempotent},
    'variant creation is idempotent'
);
is( scalar @{ $variants->created },
    1, 'idempotent variant creation avoids duplicates' );

my $orphan = $attachments->create(
    {
        attachment_id     => 'orphan-1',
        owner_user_id     => 'user-1',
        object_key        => 'attachments/user-1/orphan-1',
        original_filename => 'orphan.txt',
        media_type        => 'text/plain',
        byte_size         => 12,
        checksum          => 'orphan',
        state             => 'intent',
        scan_status       => 'pending',
        created_at        => '2026-05-23T11:00:00Z',
        deleted_at        => undef,
    }
);
my $active = $attachments->create(
    {
        attachment_id     => 'active-1',
        owner_user_id     => 'user-1',
        object_key        => 'attachments/user-1/active-1',
        original_filename => 'active.txt',
        media_type        => 'text/plain',
        byte_size         => 12,
        checksum          => 'active',
        state             => 'intent',
        scan_status       => 'pending',
        created_at        => '2026-05-23T11:00:00Z',
        deleted_at        => undef,
    }
);
$links->create(
    {
        attachment_link_id => 'link-active',
        attachment_id      => 'active-1',
        target_id          => 'post-1',
        target_type        => 'post',
        created_at         => '2026-05-23T12:00:00Z',
    }
);
my $cleanup = $store->cleanup_orphans( { actor_id => 'worker', limit => 10 } );
is( scalar @{ $cleanup->{deleted} }, 1,         'cleanup deletes one orphan' );
is( $orphan->get_column('state'),    'deleted', 'cleanup soft-deletes orphan' );
is( $active->get_column('state'), 'intent', 'cleanup keeps linked attachment' );

my $sink = GPForum::Test::WorkerSink->new;
my $scan_handler =
  GPForum::Worker::Handler::AttachmentScanning->new( sink => $sink );
my $media_handler =
  GPForum::Worker::Handler::MediaProcessing->new( sink => $sink );
my $uploaded_event = {
    event_id       => 'event-1',
    event_type     => 'attachment.uploaded',
    aggregate_id   => 'generated-1',
    aggregate_type => 'attachment',
};
my $scanned_event = {
    event_id       => 'event-2',
    event_type     => 'attachment.scanned',
    aggregate_id   => 'generated-1',
    aggregate_type => 'attachment',
    scan_status    => 'clean',
};

ok(
    $scan_handler->supports($uploaded_event),
    'scan handler supports upload event'
);
is( $scan_handler->handle($uploaded_event)->{action},
    'attachment.scan', 'scan handler emits scan task' );
ok(
    $media_handler->supports($scanned_event),
    'media handler supports clean scanned event'
);
is( $media_handler->handle($scanned_event)->{action},
    'media.process', 'media handler emits processing task' );
is( scalar @{ $sink->records }, 2, 'attachment workers write sink records' );

my $pipeline_fixtures = _pipeline_fixtures();
my $pipeline_storage  = GPForum::Service::Attachment::FilesystemStorage->new(
    root => tempdir( CLEANUP => 1 ) );
my $pipeline_store = GPForum::Service::Attachment::Store->new(
    schema     => $pipeline_fixtures->{schema},
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
);
my $pipeline_ids = GPForum::Test::Id->new;
my $pipeline     = GPForum::Service::Attachment::UploadPipeline->new(
    intent_builder => GPForum::Service::Attachment::IntentBuilder->new(
        clock      => GPForum::Test::FixedClock->new,
        id_service => $pipeline_ids,
    ),
    storage => $pipeline_storage,
    store   => $pipeline_store,
);
my $pipeline_uploaded = $pipeline->upload_and_link(
    {
        actor_user_id     => 'user-1',
        content           => $PNG_BYTES,
        media_type        => 'text/plain',
        original_filename => 'photo.png',
        target_id         => 'post-99',
        target_type       => 'post',
    }
);
ok( $pipeline_uploaded->{ok}, 'upload pipeline accepts valid file content' );
is( $pipeline_uploaded->{attachment}{media_type},
    'image/png', 'upload pipeline uses sniffed media type' );
is( $pipeline_uploaded->{attachment}{state},
    'available',
    'upload pipeline makes locally validated attachment available' );
ok(
    $pipeline_storage->exists_object(
        $pipeline_uploaded->{attachment}{object_key}
    ),
    'upload pipeline writes object to filesystem storage'
);
is( scalar @{ $pipeline_fixtures->{links}->created },
    1, 'upload pipeline links attachment to post' );

my $delivery = GPForum::Service::Attachment::Delivery->new(
    storage => $pipeline_storage,
    store   => $pipeline_store,
);
my $delivered = $delivery->download(
    {
        attachment_id  => $pipeline_uploaded->{attachment}{attachment_id},
        viewer_user_id => undef,
    }
);
ok( $delivered->{ok}, 'delivery returns public attachment' );
is( $delivered->{content}, $PNG_BYTES, 'delivery reads stored object content' );

my $processor = GPForum::Service::Attachment::MediaProcessor->new(
    storage => $pipeline_storage,
    store   => $pipeline_store,
);
my $processed =
  $processor->process( $pipeline_uploaded->{attachment}{attachment_id} );
ok( $processed->{ok}, 'media processor handles image attachment' );
is( $processed->{variant}{variant_type},
    'thumbnail', 'media processor creates thumbnail variant' );
ok(
    $processor->process( $pipeline_uploaded->{attachment}{attachment_id} )
      ->{variant}{idempotent},
    'media processor retry is idempotent'
);
is( scalar @{ $pipeline_fixtures->{variants}->created },
    1, 'media processor retry avoids duplicate variants' );

my $scanning_worker = GPForum::Worker::Handler::AttachmentScanning->new(
    storage => $pipeline_storage,
    store   => $pipeline_store,
);
my $event_count_before_retry =
  scalar @{ $pipeline_fixtures->{events}->created };
my $scan_retry = $scanning_worker->handle(
    {
        event_id       => 'event-uploaded-retry',
        event_type     => 'attachment.uploaded',
        aggregate_id   => $pipeline_uploaded->{attachment}{attachment_id},
        aggregate_type => 'attachment',
    }
);
ok( $scan_retry->{scan}{idempotent}, 'scanner retry is idempotent' );
is( scalar @{ $pipeline_fixtures->{events}->created },
    $event_count_before_retry, 'scanner retry avoids duplicate scan events' );

my $media_worker =
  GPForum::Worker::Handler::MediaProcessing->new( processor => $processor, );
my $media_retry = $media_worker->handle(
    {
        event_id       => 'event-scanned-retry',
        event_type     => 'attachment.scanned',
        aggregate_id   => $pipeline_uploaded->{attachment}{attachment_id},
        aggregate_type => 'attachment',
        scan_status    => 'clean',
    }
);
ok(
    $media_retry->{media}{variant}{idempotent},
    'media worker retry is idempotent'
);

done_testing();

sub _pipeline_fixtures {
    my $attachments = GPForum::Test::AttachmentResultSet->new;
    my $links       = GPForum::Test::AttachmentResultSet->new;
    my $variants    = GPForum::Test::AttachmentResultSet->new;
    my $events      = GPForum::Test::AttachmentResultSet->new;
    my $audits      = GPForum::Test::AttachmentResultSet->new;
    my $outbox      = GPForum::Test::AttachmentResultSet->new;
    my $posts       = GPForum::Test::AttachmentResultSet->new;
    $posts->create(
        {
            post_id          => 'post-99',
            author_user_id   => 'user-1',
            visibility       => 'public',
            moderation_state => 'visible',
            deleted_at       => undef,
            hidden_at        => undef,
        }
    );

    return {
        attachments => $attachments,
        links       => $links,
        variants    => $variants,
        events      => $events,
        audits      => $audits,
        outbox      => $outbox,
        posts       => $posts,
        schema      => GPForum::Test::AttachmentSchema->new(
            resultsets => {
                Attachment        => $attachments,
                AttachmentLink    => $links,
                AttachmentVariant => $variants,
                EventLog          => $events,
                AuditLog          => $audits,
                OutboxMessage     => $outbox,
                Post              => $posts,
            },
        ),
    };
}

1;
