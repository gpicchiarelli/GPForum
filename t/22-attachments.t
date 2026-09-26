# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
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
use GPForum::Test::CountingAttachmentStorage;
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

my $same_intent = $store->create_intent($intent);
ok( $same_intent->{skipped}, 'already-stored attachment intent is skipped' );
is( scalar @{ $attachments->created },
    1, 'already-stored intent does not insert another attachment' );
is( scalar @{ $events->created },
    1, 'already-stored intent does not insert another event' );
$attachments->find_misses(1);
my $raced_intent = $store->create_intent($intent);
ok( $raced_intent->{skipped},
    'unique attachment intent race reuses the object key' );
is( scalar @{ $attachments->created },
    1, 'unique attachment intent race does not insert another row' );
is( scalar @{ $events->created },
    1, 'unique attachment intent race does not insert another event' );

my $id_attachments = GPForum::Test::AttachmentResultSet->new;
my $id_events      = GPForum::Test::AttachmentResultSet->new;
my $id_audits      = GPForum::Test::AttachmentResultSet->new;
my $id_outbox      = GPForum::Test::AttachmentResultSet->new;
my $id_schema      = GPForum::Test::AttachmentSchema->new(
    resultsets => {
        Attachment    => $id_attachments,
        EventLog      => $id_events,
        AuditLog      => $id_audits,
        OutboxMessage => $id_outbox,
    },
);
$id_attachments->create(
    {
        attachment_id => 'att-seed',
        object_key    => 'attachments/user-other/att-seed',
        owner_user_id => 'user-other',
        state         => 'intent',
    }
);
my $id_store = GPForum::Service::Attachment::Store->new(
    schema     => $id_schema,
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
);
my $id_created = $id_store->create_intent(
    {
        attachment_id     => 'att-seed',
        byte_size         => 12,
        checksum          => 'abc',
        created_at        => '2026-05-23T12:00:00Z',
        media_type        => 'image/jpeg',
        object_key        => 'attachments/user-1/att-seed',
        original_filename => 'photo.jpg',
        owner_user_id     => 'user-1',
        scan_status       => 'pending',
        state             => 'intent',
    }
);
ok( $id_created->{ok}, 'unique attachment id collision remints and persists' );
ok( !$id_created->{skipped},
    'unique attachment id collision does not return another attachment' );
is( $id_attachments->created->[1]{attachment_id},
    'generated-1', 'unique attachment id collision remints the id' );
is(
    $id_attachments->created->[1]{object_key},
    'attachments/user-1/generated-1',
    'unique attachment id collision remints the object key'
);
is( scalar @{ $id_attachments->created },
    2, 'unique attachment id collision inserts this attachment' );

my $leftover_attachments = GPForum::Test::AttachmentResultSet->new;
my $leftover_events      = GPForum::Test::AttachmentResultSet->new;
my $leftover_audits      = GPForum::Test::AttachmentResultSet->new;
my $leftover_outbox      = GPForum::Test::AttachmentResultSet->new;
$leftover_attachments->create(
    {
        attachment_id => 'generated-1',
        object_key    => 'attachments/user-leftover/generated-1',
        owner_user_id => 'user-leftover',
        state         => 'intent',
    }
);
$leftover_attachments->find_misses(1);
my $leftover_store = GPForum::Service::Attachment::Store->new(
    schema => GPForum::Test::AttachmentSchema->new(
        resultsets => {
            Attachment    => $leftover_attachments,
            EventLog      => $leftover_events,
            AuditLog      => $leftover_audits,
            OutboxMessage => $leftover_outbox,
        },
    ),
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
);
my $leftover_intent = $leftover_store->create_intent(
    {
        attachment_id     => 'generated-1',
        byte_size         => 12,
        checksum          => 'abc',
        created_at        => '2026-05-23T12:00:00Z',
        media_type        => 'image/jpeg',
        object_key        => 'attachments/user-leftover/generated-1',
        original_filename => 'photo.jpg',
        owner_user_id     => 'user-leftover',
        scan_status       => 'pending',
        state             => 'intent',
    }
);
ok( $leftover_intent->{skipped},
    'leftover attachment id race reuses this attachment' );
is( $leftover_intent->{attachment}->get_column('attachment_id'),
    'generated-1', 'leftover attachment id race keeps this attachment' );
is( scalar @{ $leftover_attachments->created },
    1, 'leftover attachment id race does not insert a second attachment' );
is( scalar @{ $leftover_events->created },
    1, 'leftover attachment id race inserts the missing event' );
is( scalar @{ $leftover_outbox->created },
    1, 'leftover attachment id race inserts the missing outbox row' );
is( scalar @{ $leftover_audits->created },
    1, 'leftover attachment id race inserts the missing audit row' );

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

my $linked_again = $store->link_attachment(
    {
        attachment_id => 'generated-1',
        target_type   => 'post',
        target_id     => 'post-1',
    }
);
ok( $linked_again->{idempotent}, 'attachment link create is idempotent' );
is( scalar @{ $links->created },
    1, 'idempotent attachment link avoids a second row' );

$links->skip_search(1);
my $raced_link = $store->link_attachment(
    {
        attachment_id => 'generated-1',
        target_type   => 'post',
        target_id     => 'post-1',
    }
);
ok( $raced_link->{idempotent},
    'unique attachment link race reuses the target' );
is( scalar @{ $links->created },
    1, 'unique attachment link race does not insert a second row' );

my $link_id_rs = GPForum::Test::AttachmentResultSet->new;
$link_id_rs->create(
    {
        attachment_id      => 'att-other',
        attachment_link_id => 'generated-1',
        target_id          => 'post-other',
        target_type        => 'post',
    }
);
my $link_id_store = GPForum::Service::Attachment::Store->new(
    schema => GPForum::Test::AttachmentSchema->new(
        resultsets => { AttachmentLink => $link_id_rs },
    ),
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
);
my $id_link = $link_id_store->link_attachment(
    {
        attachment_id => 'att-ours',
        target_id     => 'post-1',
        target_type   => 'post',
    }
);
ok( !$id_link->{idempotent},
    'unique attachment link id collision does not reuse another link' );
is( $id_link->{attachment_link_id},
    'generated-2', 'unique attachment link id collision remints the id' );
is( $id_link->{attachment_id},
    'att-ours', 'unique attachment link id collision keeps this attachment' );
is( scalar @{ $link_id_rs->created },
    2, 'unique attachment link id collision inserts one retried link' );

my $link_leftover_rs = GPForum::Test::AttachmentResultSet->new;
$link_leftover_rs->create(
    {
        attachment_id      => 'att-leftover',
        attachment_link_id => 'generated-1',
        target_id          => 'post-leftover',
        target_type        => 'post',
    }
);
$link_leftover_rs->skip_search(1);
my $link_leftover_store = GPForum::Service::Attachment::Store->new(
    schema => GPForum::Test::AttachmentSchema->new(
        resultsets => { AttachmentLink => $link_leftover_rs },
    ),
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
);
my $link_leftover = $link_leftover_store->link_attachment(
    {
        attachment_id => 'att-leftover',
        target_id     => 'post-leftover',
        target_type   => 'post',
    }
);
ok( $link_leftover->{idempotent},
    'leftover attachment link id race reuses this link' );
is( $link_leftover->{attachment_link_id},
    'generated-1', 'leftover attachment link id race keeps this link' );
is( $link_leftover->{attachment_id},
    'att-leftover', 'leftover attachment link id race keeps this attachment' );
is( scalar @{ $link_leftover_rs->created },
    1, 'leftover attachment link id race does not insert a second link' );

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

$variants->skip_search(2);
my $raced_variant = $store->add_variant(
    {
        attachment_id => 'generated-1',
        variant_type  => 'thumbnail',
        object_key    => 'attachments/user-1/generated-1/thumb',
        media_type    => 'image/webp',
        byte_size     => $VARIANT_BYTES,
    }
);
ok( $raced_variant->{idempotent},
    'unique attachment variant race reuses the variant type' );
is( scalar @{ $variants->created },
    1, 'unique attachment variant race does not insert a second row' );

my $keyed_variant = $store->add_variant(
    {
        attachment_id => 'generated-1',
        byte_size     => $VARIANT_BYTES,
        media_type    => 'image/webp',
        object_key    => 'attachments/user-1/generated-1/thumb',
        variant_type  => 'preview',
    }
);
ok( $keyed_variant->{idempotent}, 'variant object key reuse is idempotent' );
is( scalar @{ $variants->created },
    1, 'variant object key reuse does not insert another row' );
$variants->skip_search(2);
my $raced_key = $store->add_variant(
    {
        attachment_id => 'generated-1',
        byte_size     => $VARIANT_BYTES,
        media_type    => 'image/webp',
        object_key    => 'attachments/user-1/generated-1/thumb',
        variant_type  => 'preview',
    }
);
ok( $raced_key->{idempotent},
    'unique variant object-key race reuses the stored blob' );
is( scalar @{ $variants->created },
    1, 'unique variant object-key race does not insert a second row' );

my $variant_id_rs = GPForum::Test::AttachmentResultSet->new;
$variant_id_rs->create(
    {
        attachment_id         => 'att-other',
        attachment_variant_id => 'generated-1',
        object_key            => 'attachments/user-other/att-other/thumb',
        variant_type          => 'thumbnail',
    }
);
my $variant_id_store = GPForum::Service::Attachment::Store->new(
    schema => GPForum::Test::AttachmentSchema->new(
        resultsets => { AttachmentVariant => $variant_id_rs },
    ),
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
);
my $id_variant = $variant_id_store->add_variant(
    {
        attachment_id => 'att-ours',
        byte_size     => $VARIANT_BYTES,
        media_type    => 'image/webp',
        object_key    => 'attachments/user-1/att-ours/thumb',
        variant_type  => 'thumbnail',
    }
);
ok( !$id_variant->{idempotent},
    'unique variant id collision does not reuse another variant' );
is( $id_variant->{attachment_variant_id},
    'generated-2', 'unique variant id collision remints the id' );
is( $id_variant->{attachment_id},
    'att-ours', 'unique variant id collision keeps this attachment' );
is( scalar @{ $variant_id_rs->created },
    2, 'unique variant id collision inserts one retried variant' );

my $variant_leftover_rs = GPForum::Test::AttachmentResultSet->new;
$variant_leftover_rs->create(
    {
        attachment_id         => 'att-leftover',
        attachment_variant_id => 'generated-1',
        object_key            => 'attachments/user-leftover/att-leftover/thumb',
        variant_type          => 'thumbnail',
    }
);
$variant_leftover_rs->skip_search(2);
my $variant_leftover_store = GPForum::Service::Attachment::Store->new(
    schema => GPForum::Test::AttachmentSchema->new(
        resultsets => { AttachmentVariant => $variant_leftover_rs },
    ),
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
);
my $variant_leftover = $variant_leftover_store->add_variant(
    {
        attachment_id => 'att-leftover',
        byte_size     => $VARIANT_BYTES,
        media_type    => 'image/webp',
        object_key    => 'attachments/user-leftover/att-leftover/thumb',
        variant_type  => 'thumbnail',
    }
);
ok( $variant_leftover->{idempotent},
    'leftover variant id race reuses this variant' );
is( $variant_leftover->{attachment_variant_id},
    'generated-1', 'leftover variant id race keeps this variant' );
is( $variant_leftover->{attachment_id},
    'att-leftover', 'leftover variant id race keeps this attachment' );
is( scalar @{ $variant_leftover_rs->created },
    1, 'leftover variant id race does not insert a second variant' );

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

my $author_delete = $store->delete_linked(
    {
        actor_id      => 'user-1',
        attachment_id => 'active-1',
        target_id     => 'post-1',
        target_type   => 'post',
    }
);
ok( $author_delete->{ok}, 'delete_linked removes a linked attachment' );
is( $active->get_column('state'),
    'deleted', 'delete_linked soft-deletes the linked attachment' );
ok( !$author_delete->{idempotent},
    'delete_linked is not a replay on the first delete' );

my $author_replay = $store->delete_linked(
    {
        actor_id      => 'user-1',
        attachment_id => 'active-1',
        target_id     => 'post-1',
        target_type   => 'post',
    }
);
ok( $author_replay->{ok}, 'delete_linked replays an already-deleted row' );
ok( $author_replay->{idempotent},
    'delete_linked marks an already-deleted row as idempotent' );

my $unlinked_delete = $store->delete_linked(
    {
        actor_id      => 'user-1',
        attachment_id => 'active-1',
        target_id     => 'post-missing',
        target_type   => 'post',
    }
);
ok( !$unlinked_delete->{ok}, 'delete_linked rejects a missing post link' );
is( $unlinked_delete->{error},
    'not_found', 'delete_linked names a missing post link' );

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

# Delivery used to read the whole object into a scalar here. It now names the
# object so the caller can stream it, and the bytes must never be materialized
# on this path -- that is the whole point of the change.
ok( !exists $delivered->{content},
    'delivery does not read the object into memory' );
ok( defined $delivered->{object_path}, 'delivery names the stored object' );
ok( -e $delivered->{object_path},      'the named object path exists on disk' );
is( _slurp_bytes( $delivered->{object_path} ),
    $PNG_BYTES, 'the named object holds the stored bytes' );

# The claim is that an authorized download reads nothing. Counting the reads
# is the only way to hold it: an assertion about the returned hash would still
# pass if the bytes were read and then discarded.
my $counted_storage =
  GPForum::Test::CountingAttachmentStorage->new( inner => $pipeline_storage, );
my $counted_delivery = GPForum::Service::Attachment::Delivery->new(
    storage => $counted_storage,
    store   => $pipeline_store,
);
my $counted = $counted_delivery->download(
    {
        attachment_id  => $pipeline_uploaded->{attachment}{attachment_id},
        viewer_user_id => undef,
    }
);
ok( $counted->{ok}, 'counted delivery authorizes the download' );
is( scalar @{ $counted_storage->reads },
    0, 'an authorized download reads no bytes from storage' );

my $media_storage =
  GPForum::Test::CountingAttachmentStorage->new( inner => $pipeline_storage, );
my $processor = GPForum::Service::Attachment::MediaProcessor->new(
    storage => $media_storage,
    store   => $pipeline_store,
);
my $processed =
  $processor->process( $pipeline_uploaded->{attachment}{attachment_id} );
ok( $processed->{ok}, 'media processor handles image attachment' );
is( $processed->{variant}{variant_type},
    'thumbnail', 'media processor creates thumbnail variant' );
is( scalar @{ $media_storage->reads },
    1, 'media processor reads the original object once' );
my $replayed_media =
  $processor->process( $pipeline_uploaded->{attachment}{attachment_id} );
ok( $replayed_media->{skipped},
    'already-applied thumbnail skip does not reread storage' );
ok(
    $replayed_media->{variant}{idempotent},
    'media processor retry is idempotent'
);
is( scalar @{ $media_storage->reads },
    1, 'already-applied thumbnail does not reread the object' );
is( scalar @{ $pipeline_fixtures->{variants}->created },
    1, 'media processor retry avoids duplicate variants' );

my $scanning_worker = GPForum::Worker::Handler::AttachmentScanning->new(
    storage => GPForum::Test::CountingAttachmentStorage->new(
        inner => $pipeline_storage,
    ),
    store => $pipeline_store,
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
is( scalar @{ $scanning_worker->storage->reads },
    0, 'already-scanned attachment does not reread the object' );
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

sub _slurp_bytes {
    my ($path) = @_;

    open my $handle, '<', $path
      or croak "open $path: $ERRNO";
    binmode $handle;
    local $INPUT_RECORD_SEPARATOR = undef;
    my $bytes = <$handle>;
    close $handle
      or croak "close $path: $ERRNO";

    return $bytes;
}

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
