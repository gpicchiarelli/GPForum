# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Schema::Result::Attachment;
use GPForum::Service::Attachment::IntentBuilder;
use GPForum::Service::Attachment::Lifecycle;
use GPForum::Service::Attachment::Validator;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::WorkerSink;
use GPForum::Worker::Handler::AttachmentScanning;
use GPForum::Worker::Handler::MediaProcessing;

our $VERSION = '0.001';

const my $MAX_BYTES_PLUS_ONE => 25 * 1_024 * 1_024 + 1;
const my $VALID_BYTES        => 4_096;
const my $NOON               => 1_779_537_600;            # 2026-05-23T12:00:00Z
const my $A_DAY              => 86_400;
const my $AN_HOUR            => 3_600;

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

# A stored row, as DBIx::Class hands it over: columns through get_columns, and
# no data method. Record::row_hash copies only a hash or a row with data, so
# every replay built from a stored row came back empty.
my $lifecycle = GPForum::Service::Attachment::Lifecycle->new(
    clock => GPForum::Test::FixedClock->new( epoch => $NOON ) );
my $stored = GPForum::Schema::Result::Attachment->new(
    { attachment_id => 'att-1', object_key => 'attachments/u/att-1' } );
is_deeply(
    $lifecycle->row_columns($stored),
    { attachment_id => 'att-1', object_key => 'attachments/u/att-1' },
    'a stored row is copied with its columns'
);
is_deeply(
    $lifecycle->deleted_replay($stored),
    {
        attachment =>
          { attachment_id => 'att-1', object_key => 'attachments/u/att-1' },
        idempotent => 1,
        ok         => 1,
    },
    'and a replayed delete reports the attachment it found'
);
is_deeply( $lifecycle->row_columns(undef), {}, 'no row copies as nothing' );

# An intent becomes an orphan a day after it was written: before that it may
# be an upload still in flight.
is( $lifecycle->orphan_min_age( {} ), $A_DAY, 'orphans are a day old' );
is( $lifecycle->orphan_min_age( { min_age => $AN_HOUR } ),
    $AN_HOUR, 'unless the run says otherwise' );
is( $lifecycle->orphan_min_age( { min_age => 0 } ),
    $A_DAY, 'and never no age at all' );
is( $lifecycle->orphan_min_age( { min_age => -$AN_HOUR } ),
    $A_DAY, 'nor one that would put the cutoff in the future' );
is( $lifecycle->orphan_min_age( { min_age => '1h' } ),
    $A_DAY, 'nor one that is not a number of seconds' );
is( $lifecycle->orphan_cutoff( {} ),
    '2026-05-22T12:00:00Z', 'the cutoff is a day before the clock' );
is( $lifecycle->orphan_cutoff( { min_age => $AN_HOUR } ),
    '2026-05-23T11:00:00Z', 'or the age the run gives' );
ok(
    $lifecycle->still_intent( { state => 'intent' } ),
    'an intent is still the purge\'s to take'
);
ok( !$lifecycle->still_intent( { state => 'deleted' } ),
    'one another run deleted is not' );
is_deeply(
    $lifecycle->cleanup_result( ['att-1'], ['att-2: unsafe key'] ),
    { deleted => ['att-1'], errors => ['att-2: unsafe key'], ok => 0 },
    'an orphan that could not be purged fails the run'
);

# The store, its links, scan verdicts, variants, deletions and orphan purge,
# the upload pipeline, delivery and the workers' retries run on PostgreSQL:
# t/integration/postgres-attachments.t.

done_testing();

1;
