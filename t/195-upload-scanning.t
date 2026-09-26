# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::Exception;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Attachment::DownloadAccess;
use GPForum::Service::Attachment::Scanner;
use GPForum::Service::Operations::ScheduledJobs;
use GPForum::Test::Antivirus;
use GPForum::Test::AttachmentFixtures;
use GPForum::Worker::Handler::AttachmentScanning;

our $VERSION = '0.001';

const my $PNG_BYTES      => pack( 'H*', '89504e470d0a1a0a' ) . 'attachment';
const my $PENDING_LOOKUP => 10;

# ADR 0108: uploads are scanned by the antivirus the operating system
# installed, and nothing is served until something has decided it is clean.
my $access = GPForum::Service::Attachment::DownloadAccess->new;

# Scanning off: the media type check is the whole verdict, and says so.
{
    my $fixture = GPForum::Test::AttachmentFixtures->build;
    my $row     = _upload($fixture);
    is( _column( $row, 'scan_status' ), 'clean', 'scanning off: clean' );
    is( _column( $row, 'scan_engine' ),
        'format-check', 'and the row says only the format was checked' );
    ok( $access->downloadable($row), 'and it is served' );
}

# A fast scanner (clamd) decides inside the upload.
{
    my $fixture = GPForum::Test::AttachmentFixtures->build(
        antivirus => GPForum::Test::Antivirus->new );
    my $row = _upload($fixture);
    is( _column( $row, 'scan_status' ), 'clean', 'clamd: clean at upload' );
    is( _column( $row, 'scan_engine' ),
        'Fake 1/1', 'the engine that decided is recorded' );
    ok( $access->downloadable($row), 'a clean file is served' );
}
{
    my $fixture = GPForum::Test::AttachmentFixtures->build(
        antivirus => _scanner( infected => 'Test.Malware' ) );
    my $row = _upload($fixture);
    is( _column( $row, 'scan_status' ),
        'infected', 'clamd: malware is recorded as infected' );
    is( _column( $row, 'scan_signature' ),
        'Test.Malware', 'with the name of what was found' );
    is( _column( $row, 'state' ), 'quarantined', 'the file is quarantined' );
    ok( !$access->downloadable($row), 'and never served' );
}

# An antivirus that cannot answer leaves the upload pending, unserved.
my $pending_fixture = GPForum::Test::AttachmentFixtures->build(
    antivirus => _scanner( error => 'cannot connect' ) );
my $pending = _upload($pending_fixture);
is( _column( $pending, 'scan_status' ),
    'pending', 'clamd unreachable: the upload stays pending' );
ok( !$access->downloadable($pending), 'and a pending file is not served' );

# A slow scanner (a process per file) is left to the worker.
{
    my $slow = GPForum::Test::Antivirus->new( immediate => 0 );
    my $fixture =
      GPForum::Test::AttachmentFixtures->build( antivirus => $slow );
    my $row = _upload($fixture);
    is( _column( $row, 'scan_status' ),
        'pending', 'a slow scanner leaves the upload pending' );
    is( $slow->scans, 0, 'without scanning inside the request' );
}

# The worker decides what the upload could not.
{
    my $failing = _worker( $pending_fixture, _scanner( error => 'timeout' ) );
    throws_ok { $failing->handle( _uploaded_event($pending) ) }
    qr/antivirus [ ] could [ ] not [ ] scan/msx,
      'an antivirus error hands the event back to the outbox to retry';
    is( _column( _reload( $pending_fixture, $pending ), 'scan_status' ),
        'pending', 'and the attachment is still pending, still unserved' );

    my $scanning = _worker( $pending_fixture, GPForum::Test::Antivirus->new );
    $scanning->handle( _uploaded_event($pending) );
    my $scanned = _reload( $pending_fixture, $pending );
    is( _column( $scanned, 'scan_status' ),
        'clean', 'the retry scans it clean' );
    ok( $access->downloadable($scanned), 'and it is served' );
}

# Uploads still pending after the outbox gave up are picked up by the hourly
# scheduled jobs once the antivirus answers again.
{
    my $fixture = GPForum::Test::AttachmentFixtures->build(
        antivirus => _scanner( error => 'down' ) );
    my $first = _upload($fixture);
    my $later = _upload($fixture);
    is_deeply(
        [ sort @{ $fixture->{store}->pending_scan_ids($PENDING_LOOKUP) } ],
        [ sort map { _column( $_, 'attachment_id' ) } $first, $later ],
        'both uploads wait, pending'
    );

    my $still_down =
      _jobs( $fixture, GPForum::Test::Antivirus->new( reachable => 0 ) )
      ->rescan_pending_uploads( {} );
    is( $still_down->{ok},      0, 'the rescan fails while clamd is down' );
    is( $still_down->{scanned}, 0, 'without trying a single file' );
    like( $still_down->{error}, qr/unavailable/msx, 'and says why' );

    my $recovered = _jobs( $fixture, GPForum::Test::Antivirus->new )
      ->rescan_pending_uploads( {} );
    is( $recovered->{scanned}, 2,
        'once clamd answers, the backlog is scanned' );
    is_deeply( $fixture->{store}->pending_scan_ids($PENDING_LOOKUP),
        [], 'and nothing is left pending' );
    ok( $access->downloadable( _reload( $fixture, $first ) ),
        'the files are served' );
}

# One file the antivirus always fails on does not hold back the others.
{
    my $fixture = GPForum::Test::AttachmentFixtures->build(
        antivirus => _scanner( error => 'down' ) );
    my $stuck = _upload( $fixture, $PNG_BYTES . 'STUCK' );
    my $fine  = _upload($fixture);
    my $run =
      _jobs( $fixture,
        GPForum::Test::Antivirus->new( fails_on => qr/STUCK/msx ) )
      ->rescan_pending_uploads( {} );
    is( $run->{scanned}, 1, 'the rescan goes on past a file that fails' );
    like( $run->{errors}[0], qr/always [ ] fails/msx, 'and reports it' );
    ok(
        $access->downloadable( _reload( $fixture, $fine ) ),
        'so the next file is scanned and served'
    );
    is( _column( _reload( $fixture, $stuck ), 'scan_attempts' ),
        1, 'the failure is counted on the file' );
    like(
        _column( _reload( $fixture, $stuck ), 'scan_error' ),
        qr/always [ ] fails/msx,
        'with the error, for the operator'
    );
}

# A batch no larger than the files that keep failing still makes progress:
# files with fewer attempts come first, so the same failures are not picked
# again every hour ahead of everything else.
{
    my $fixture = GPForum::Test::AttachmentFixtures->build(
        antivirus => _scanner( error => 'down' ) );
    my $stuck = _upload( $fixture, $PNG_BYTES . 'STUCK' );
    my $fresh = _upload($fixture);
    my $jobs  = _jobs( $fixture,
        GPForum::Test::Antivirus->new( fails_on => qr/STUCK/msx ) );
    my $first = $jobs->rescan_pending_uploads( { limit => 1 } );
    is( $first->{scanned}, 0,
        'a batch of one takes the oldest file and fails' );
    my $retried = $jobs->rescan_pending_uploads( { limit => 1 } );
    is( $retried->{scanned}, 1, 'the next batch takes the file not yet tried' );
    ok( $access->downloadable( _reload( $fixture, $fresh ) ),
        'which is served' );
}

# Files served on a format check alone -- uploaded before scanning existed --
# go through the antivirus once one is configured.
{
    my $fixture   = GPForum::Test::AttachmentFixtures->build;
    my $ordinary  = _upload($fixture);
    my $malicious = _upload( $fixture, $PNG_BYTES . 'MALWARE' );
    ok(
        $access->downloadable( _reload( $fixture, $malicious ) ),
        'before the backfill a format-checked file is served'
    );

    my $off = _jobs( $fixture, undef )->backfill_unscanned_uploads( {} );
    is( $off->{skipped}, 'scanning is off', 'nothing to backfill with' );

    my $run =
      _jobs( $fixture,
        GPForum::Test::Antivirus->new( detects => qr/MALWARE/msx ) )
      ->backfill_unscanned_uploads( {} );
    is( $run->{scanned}, 2, 'the backfill scans every format-checked file' );
    my $quarantined = _reload( $fixture, $malicious );
    is( _column( $quarantined, 'scan_status' ),
        'infected', 'malware among them is found' );
    ok( !$access->downloadable($quarantined), 'and withdrawn' );
    my $confirmed = _reload( $fixture, $ordinary );
    is( _column( $confirmed, 'scan_engine' ),
        'Fake 1/1', 'a clean one records the engine that confirmed it' );
    ok( $access->downloadable($confirmed), 'and stays served' );
    is_deeply( $fixture->{store}->unscanned_clean_ids($PENDING_LOOKUP),
        [], 'and none is scanned twice' );
}

# Two scans race: a fast one finds malware, a slow one with older signatures
# then says clean. The first verdict stands; clean never replaces infected.
{
    my $fixture = GPForum::Test::AttachmentFixtures->build(
        antivirus => _scanner( error => 'down' ) );
    my $row = _upload($fixture);
    my $id  = _column( $row, 'attachment_id' );
    $fixture->{store}->record_scan(
        {
            actor_id       => 'fast',
            attachment_id  => $id,
            scan_status    => 'infected',
            scan_signature => 'Test.Malware',
        }
    );
    my $late = $fixture->{store}->record_scan(
        { actor_id => 'slow', attachment_id => $id, scan_status => 'clean' } );
    ok( $late->{idempotent}, 'a late clean verdict is a replay' );
    my $held = _reload( $fixture, $row );
    is( _column( $held, 'scan_status' ), 'infected', 'infected stands' );
    ok( !$access->downloadable($held), 'and the file is still not served' );
}

# Deleted while pending: the scan is skipped and the deletion stands.
{
    my $fixture = GPForum::Test::AttachmentFixtures->build(
        antivirus => _scanner( error => 'down' ) );
    my $row = _upload($fixture);
    $fixture->{store}->soft_delete( _column( $row, 'attachment_id' ),
        'user-1', 'author delete' );
    my $result = _worker( $fixture, GPForum::Test::Antivirus->new )
      ->handle( _uploaded_event($row) );
    is( $result->{scan}{skipped},
        'deleted', 'an upload deleted while pending is not scanned' );
    is( _column( _reload( $fixture, $row ), 'state' ),
        'deleted', 'and stays deleted' );
}

# A storage read that fails leaves the upload pending, to be tried again.
{
    my $fixture = GPForum::Test::AttachmentFixtures->build(
        antivirus => _scanner( error => 'down' ) );
    my $row = _upload($fixture);
    $fixture->{storage}->delete_object( _column( $row, 'object_key' ) );
    throws_ok {
        _worker( $fixture, GPForum::Test::Antivirus->new )
          ->handle( _uploaded_event($row) );
    }
    qr/cannot [ ] read [ ] stored [ ] object/msx,
      'an unreadable object is retried, not failed for good';
    is( _column( _reload( $fixture, $row ), 'scan_status' ),
        'pending', 'the upload is still pending' );
}

# Bytes that changed after the write are a failure, not an infection.
{
    my $fixture = GPForum::Test::AttachmentFixtures->build(
        antivirus => _scanner( error => 'down' ) );
    my $row = _upload($fixture);
    $fixture->{storage}
      ->write_object( _column( $row, 'object_key' ), 'no longer a png' );
    my $worker = _worker( $fixture, GPForum::Test::Antivirus->new );
    $worker->handle( _uploaded_event($row) );
    my $checked = _reload( $fixture, $row );
    is( _column( $checked, 'scan_status' ),
        'failed', 'tampered bytes fail the check' );
    is( _column( $checked, 'scan_engine' ),
        'format-check', 'which the format check, not the antivirus, found' );
    ok( !$access->downloadable($checked), 'and are not served' );
}

done_testing();

sub _scanner {
    my ( $status, $detail ) = @_;

    my %verdict = ( status => $status, engine => 'Fake 1/1' );
    $verdict{ $status eq 'error' ? 'error' : 'signature' } = $detail;

    return GPForum::Test::Antivirus->new( verdict => \%verdict );
}

sub _jobs {
    my ( $fixture, $antivirus ) = @_;

    return GPForum::Service::Operations::ScheduledJobs->new(
        attachment_scanner => GPForum::Service::Attachment::Scanner->new(
            antivirus => $antivirus,
            storage   => $fixture->{storage},
            store     => $fixture->{store},
        ),
        attachment_store => $fixture->{store},
    );
}

sub _worker {
    my ( $fixture, $antivirus ) = @_;

    return GPForum::Worker::Handler::AttachmentScanning->new(
        antivirus => $antivirus,
        storage   => $fixture->{storage},
        store     => $fixture->{store},
    );
}

sub _upload {
    my ( $fixture, $content ) = @_;

    my $uploaded = $fixture->{pipeline}->upload_and_link(
        {
            actor_user_id     => 'user-1',
            content           => defined $content ? $content : $PNG_BYTES,
            media_type        => 'image/png',
            original_filename => 'photo.png',
            target_id         => 'post-99',
            target_type       => 'post',
        }
    );

    return $fixture->{store}
      ->find_attachment( $uploaded->{attachment}{attachment_id} );
}

sub _reload {
    my ( $fixture, $row ) = @_;

    return $fixture->{store}
      ->find_attachment( _column( $row, 'attachment_id' ) );
}

sub _uploaded_event {
    my ($row) = @_;

    return {
        aggregate_id   => _column( $row, 'attachment_id' ),
        aggregate_type => 'attachment',
        event_id       => 'event-upload',
        event_type     => 'attachment.uploaded',
    };
}

sub _column {
    my ( $row, $name ) = @_;

    return ref $row eq 'HASH' ? $row->{$name} : $row->get_column($name);
}

1;
