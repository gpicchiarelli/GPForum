# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Attachment::IntentBuilder;
use GPForum::Service::Attachment::Validator;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::WorkerSink;
use GPForum::Worker::Handler::AttachmentScanning;
use GPForum::Worker::Handler::MediaProcessing;

our $VERSION = '0.001';

const my $MAX_BYTES_PLUS_ONE => 25 * 1_024 * 1_024 + 1;
const my $VALID_BYTES        => 4_096;

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

# The store, its links, scan verdicts, variants, deletions and orphan purge,
# the upload pipeline, delivery and the workers' retries run on PostgreSQL:
# t/integration/postgres-attachments.t.

done_testing();

1;
