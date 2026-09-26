# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use File::Temp qw(tempdir);

use GPForum::Service::Attachment::DownloadAccess;
use GPForum::Service::Attachment::FilesystemStorage;
use GPForum::Service::Attachment::UploadPipeline;
use GPForum::Test::Antivirus;
use GPForum::Service::Attachment::IntentBuilder;
use GPForum::Service::Attachment::Store;
use GPForum::Test::PostgresHarness;

our $VERSION = '0.001';

const my $LOOKUP    => 100;
const my $PNG_BYTES => pack( 'H*', '89504e470d0a1a0a' ) . 'attachment';
const my $SCANNED_EVENTS_SQL => join q{ },
  'SELECT count(*) FROM event_log WHERE aggregate_id = ?',
  q{AND event_type = 'attachment.scanned'};
const my $PUBLIC_POST_SQL => join q{ },
  'SELECT post_id, author_user_id FROM posts',
  q{WHERE deleted_at IS NULL AND visibility = 'public' LIMIT 1};

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all => 'set GPFORUM_DATABASE_DSN to run the attachment scan test';
}

# ADR 0108's verdict rules against PostgreSQL rather than the doubles: the
# compare-and-set is SQL, and DBI's "0E0" for an UPDATE that matched nothing
# is exactly the kind of thing a double gets wrong.
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
GPForum::Test::PostgresHarness::prepare_database();

my $schema  = GPForum::Test::PostgresHarness::connect_schema();
my $dbh     = $schema->storage->dbh;
my ($owner) = $dbh->selectrow_array('SELECT id FROM users ORDER BY id LIMIT 1');
my $store   = GPForum::Service::Attachment::Store->new( schema => $schema );
my $access  = GPForum::Service::Attachment::DownloadAccess->new;

# A late clean never replaces infected.
my $raced = _pending_upload('raced');
$store->record_scan(
    {
        actor_id       => 'fast',
        attachment_id  => $raced,
        scan_engine    => 'ClamAV 1.4.1/27400',
        scan_signature => 'Test.Malware',
        scan_status    => 'infected',
    }
);
my $late = $store->record_scan(
    { actor_id => 'slow', attachment_id => $raced, scan_status => 'clean' } );
ok( $late->{idempotent}, 'a late clean verdict is a replay in PostgreSQL' );
is( _column( $raced, 'scan_status' ),    'infected',     'infected stands' );
is( _column( $raced, 'scan_signature' ), 'Test.Malware', 'with its signature' );
ok( !$access->downloadable( $store->find_attachment($raced) ),
    'and is not served' );
is( $dbh->selectrow_array( $SCANNED_EVENTS_SQL, undef, $raced ),
    0, 'the losing verdict records no event' );

# A clean file may still be quarantined later.
my $tightened = _pending_upload('tightened');
$store->record_scan(
    {
        actor_id      => 'scan',
        attachment_id => $tightened,
        scan_engine   => 'format-check',
        scan_status   => 'clean'
    }
);
$store->record_scan(
    {
        actor_id      => 'backfill',
        attachment_id => $tightened,
        scan_status   => 'infected',
        scan_engine   => 'ClamAV 1.4.1/27400',
    }
);
is( _column( $tightened, 'state' ),
    'quarantined', 'a clean file can be quarantined by a later scan' );

# The rescan and backfill queries.
my $waiting = _pending_upload('waiting');
ok( ( grep { $_ eq $waiting } @{ $store->pending_scan_ids($LOOKUP) } ),
    'a pending upload is found by the rescan' );
my $legacy = _pending_upload('legacy');
$store->record_scan(
    { actor_id => 'old', attachment_id => $legacy, scan_status => 'clean' } );
ok(
    ( grep { $_ eq $legacy } @{ $store->unscanned_clean_ids($LOOKUP) } ),
    'a file cleared with no engine on record is found by the backfill'
);
is(
    $store->confirm_clean(
        { attachment_id => $legacy, scan_engine => 'ClamAV 1.4.1/27400' }
    )->{confirmed},
    1,
    'and confirmed'
);
ok( !( grep { $_ eq $legacy } @{ $store->unscanned_clean_ids($LOOKUP) } ),
    'once, never again' );
is(
    $store->confirm_clean(
        { attachment_id => $legacy, scan_engine => 'ClamAV 1.4.1/27400' }
    )->{confirmed},
    0,
    'a second confirmation matches no row -- DBI\'s "0E0" read as zero'
);

# An upload, end to end, against PostgreSQL. None had ever run here: the
# verdict's event named its scanner in a uuid column, and every upload failed
# as it recorded the verdict.
my ( $post, $author ) = $dbh->selectrow_array($PUBLIC_POST_SQL);
my $storage = GPForum::Service::Attachment::FilesystemStorage->new(
    root => tempdir( CLEANUP => 1 ) );
for my $case (
    [ 'scanning off',      undef,                         'clean' ],
    [ 'with an antivirus', GPForum::Test::Antivirus->new, 'clean' ],
    [
        'with malware found',
        GPForum::Test::Antivirus->new( detects => qr/attachment/msx ),
        'infected'
    ],
  )
{
    my ( $label, $antivirus, $expected ) = @{$case};
    my $uploaded = GPForum::Service::Attachment::UploadPipeline->new(
        antivirus => $antivirus,
        storage   => $storage,
        store     => $store,
    )->upload_and_link(
        {
            actor_user_id     => $author,
            content           => $PNG_BYTES,
            media_type        => 'image/png',
            original_filename => 'photo.png',
            target_id         => $post,
            target_type       => 'post',
        }
    );
    ok( $uploaded->{ok}, "an upload succeeds against PostgreSQL, $label" )
      or diag explain $uploaded;
    is( _column( $uploaded->{attachment}{attachment_id}, 'scan_status' ),
        $expected, "and records its verdict, $label" );
}

$schema->storage->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

sub _pending_upload {
    my ($name) = @_;

    my $intent = GPForum::Service::Attachment::IntentBuilder->new->build_intent(
        {
            owner_user_id     => $owner,
            original_filename => "$name.txt",
            media_type        => 'text/plain',
            byte_size         => 1,
            checksum          => $name,
        }
    );
    $store->create_intent($intent);
    $store->mark_uploaded( $intent->{attachment_id} );

    return $intent->{attachment_id};
}

sub _column {
    my ( $id, $name ) = @_;

    return $store->find_attachment($id)->get_column($name);
}

1;
