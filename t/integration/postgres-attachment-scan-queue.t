# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::Id;
use GPForum::Service::Attachment::Store;
use GPForum::Test::FixedClock;
use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

const my $NOW_EPOCH    => 1_779_537_600;
const my $QUEUE_LIMIT  => 50;
const my $ERROR_LENGTH => 500;
const my $LONG_ERROR   => 'x' x ( $ERROR_LENGTH + 20 );
const my $USER_SQL => join q{ },
  'INSERT INTO users (id, username, display_name, email_normalized,',
  q{password_hash, status) VALUES (?, 'scanned', 'Scanned',},
  q{'scanned@example.test', 'x', 'active')};
const my $ATTACHMENT_SQL => join q{ },
  'INSERT INTO attachments (attachment_id, byte_size, checksum, created_at,',
  'uploaded_at, media_type, object_key, original_filename, owner_user_id,',
  'scan_status, scan_engine, scan_error, state) VALUES',
  q{(?, 1, 'seeded', ?, ?, 'text/plain', ?, 'seeded.txt', ?, ?, ?, ?, ?)};
const my $SEEDED_SQL =>
  'SELECT attachment_id FROM attachments WHERE owner_user_id = ?';
const my $SCAN_SQL =>
  'SELECT scan_error, scan_attempts FROM attachments WHERE attachment_id = ?';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# The rescan's and the backfill's queues (ADR 0108), which the store answers
# through Attachment::ScanQueue, on what no other test failed without: the
# rescan takes uploads in the order they were uploaded and only uploads, the
# backfill takes served files in the order they were created, a
# confirmation clears the error a failed run left, and a failure keeps no
# more of the error than the column is meant for.
my $database = GPForum::Test::PgDatabase->fresh;
my $dbh      = $database->dbh;
my $ids      = GPForum::Infrastructure::Id->new;
my $owner    = $ids->uuid;
$dbh->do( $USER_SQL, undef, $owner );
my $store = GPForum::Service::Attachment::Store->new(
    clock      => GPForum::Test::FixedClock->new( epoch => $NOW_EPOCH ),
    id_service => $ids,
    schema     => $database->schema,
);

# Created in one order, uploaded in the other.
my $uploaded_late = _attachment(
    {
        created_at  => '2026-05-01T00:00:00Z',
        scan_status => 'pending',
        state       => 'uploaded',
        uploaded_at => '2026-05-03T00:00:00Z',
    }
);
my $uploaded_early = _attachment(
    {
        created_at  => '2026-05-02T00:00:00Z',
        scan_status => 'pending',
        state       => 'uploaded',
        uploaded_at => '2026-05-02T12:00:00Z',
    }
);
_attachment( { scan_status => 'pending', state => 'intent' } );
is_deeply(
    _queued( $store->pending_scan_ids($QUEUE_LIMIT) ),
    [ $uploaded_early, $uploaded_late ],
    'the rescan takes uploads by when they were uploaded, and only uploads'
);

# Created in one order, uploaded in the other.
my $created_early = _attachment(
    {
        created_at  => '2026-04-01T00:00:00Z',
        scan_engine => 'format-check',
        scan_error  => 'antivirus unavailable',
        scan_status => 'clean',
        state       => 'available',
        uploaded_at => '2026-04-04T00:00:00Z',
    }
);
my $created_late = _attachment(
    {
        created_at  => '2026-04-02T00:00:00Z',
        scan_status => 'clean',
        state       => 'available',
        uploaded_at => '2026-04-03T00:00:00Z',
    }
);
is_deeply(
    _queued( $store->unscanned_clean_ids($QUEUE_LIMIT) ),
    [ $created_early, $created_late ],
    'the backfill takes served files by when they were created'
);

ok(
    $store->confirm_clean(
        { attachment_id => $created_early, scan_engine => 'ClamAV 1.4.1' }
    )->{confirmed},
    'a format-checked file is confirmed clean'
);
is( ( $dbh->selectrow_array( $SCAN_SQL, undef, $created_early ) )[0],
    undef, 'and the error a failed run left is cleared' );

ok( $store->record_scan_failure( $created_late, $LONG_ERROR ),
    'a failed scan is recorded' );
is_deeply(
    [ $dbh->selectrow_array( $SCAN_SQL, undef, $created_late ) ],
    [ 'x' x $ERROR_LENGTH, 1 ],
    'counted, with the error cut to its first 500 characters'
);

done_testing();

sub _attachment {
    my ($columns) = @_;

    my $attachment_id = $ids->uuid;
    $dbh->do(
        $ATTACHMENT_SQL,
        undef,
        $attachment_id,
        $columns->{created_at} // '2026-05-05T00:00:00Z',
        $columns->{uploaded_at},
        "attachments/$owner/$attachment_id",
        $owner,
        @{$columns}{qw(scan_status scan_engine scan_error state)},
    );

    return $attachment_id;
}

# The ids this test seeded, in the order the queue gave them.
sub _queued {
    my ($queue) = @_;

    my %seeded = map { $_ => 1 }
      @{ $dbh->selectcol_arrayref( $SEEDED_SQL, undef, $owner ) };

    return [ grep { $seeded{$_} } @{$queue} ];
}

1;
