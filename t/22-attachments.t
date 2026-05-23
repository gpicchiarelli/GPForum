package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Attachment::IntentBuilder;
use GPForum::Service::Attachment::Store;
use GPForum::Service::Attachment::Validator;
use GPForum::Test::AttachmentResultSet;
use GPForum::Test::AttachmentSchema;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::WorkerSink;
use GPForum::Worker::Handler::AttachmentScanning;
use GPForum::Worker::Handler::MediaProcessing;

our $VERSION = '0.001';

const my $EXPECTED_TESTS     => 41;
const my $MAX_BYTES_PLUS_ONE => 25 * 1_024 * 1_024 + 1;
const my $VALID_BYTES        => 4_096;
const my $VARIANT_BYTES      => 512;

plan tests => $EXPECTED_TESTS;

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
my $schema      = GPForum::Test::AttachmentSchema->new(
    resultsets => {
        Attachment        => $attachments,
        AttachmentLink    => $links,
        AttachmentVariant => $variants,
        EventLog          => $events,
        AuditLog          => $audits,
        OutboxMessage     => $outbox,
    },
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

1;
