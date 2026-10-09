# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Infrastructure::Id;
use GPForum::Service::Attachment::IntentBuilder;
use GPForum::Service::Attachment::Store;
use GPForum::Test::FailingEventRecorder;
use GPForum::Test::FixedClock;
use GPForum::Test::PgDatabase;

our $VERSION = '0.001';

const my $NOW_EPOCH   => 1_779_537_600;
const my $VALID_BYTES => 4_096;
const my $USER_SQL => join q{ },
  'INSERT INTO users (id, username, display_name, email_normalized,',
  q{password_hash, status) VALUES (?, ?, ?, ?, 'x', 'active')};
const my $ATTACHMENT_SQL => join q{ },
  'INSERT INTO attachments (attachment_id, byte_size, checksum, created_at,',
  'media_type, object_key, original_filename, owner_user_id, scan_status,',
  q{state) VALUES (?, 1, 'seeded', now(), 'text/plain', ?, 'seeded.txt', ?,},
  q{'pending', 'intent')};
const my $STATE_SQL =>
  'SELECT state, scan_status FROM attachments WHERE attachment_id = ?';
const my $EVENT_SQL => join q{ },
  'SELECT aggregate_id, correlation_id FROM event_log',
  'WHERE event_type = ? AND aggregate_id = ?';
const my $AUDIT_SQL => join q{ },
  'SELECT actor_id, correlation_id FROM audit_log',
  'WHERE action = ? AND target_id = ?';
const my $EVENTS_SQL => join q{ },
  'SELECT count(*) FROM event_log WHERE aggregate_id = ?';
const my $LINK_AT_SQL => join q{ },
  'SELECT created_at = ?::timestamptz FROM attachment_links',
  'WHERE attachment_link_id = ?';
const my $VARIANT_AT_SQL => join q{ },
  'SELECT created_at = ?::timestamptz FROM attachment_variants',
  'WHERE attachment_variant_id = ?';

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# What the attachment store writes beside its rows, which no other test
# failed without: each audit row shares its event's correlation id, and a
# deletion's names who deleted; a leftover found by its object key under
# another id is finished under its own id; a link and a variant are stored
# at the store's clock; and a verdict or a deletion whose event cannot be
# written leaves the row as it was.
my $database = GPForum::Test::PgDatabase->fresh;
my $dbh      = $database->dbh;
my $ids      = GPForum::Infrastructure::Id->new;
my $clock    = GPForum::Test::FixedClock->new( epoch => $NOW_EPOCH );
my %user     = map { $_ => _user($_) } qw(owner moderator);
my $store    = _store();

my $intent = _intent('recorded');
my $id     = $intent->{attachment_id};
$store->create_intent($intent);
my $uploaded = _event( 'attachment.uploaded', $id );
is_deeply(
    _audit( 'attachment.uploaded', $id ),
    [ $user{owner}, $uploaded->[1] ],
    'an intent is audited under its owner and its event\'s correlation id'
);

$store->soft_delete( $id, $user{moderator}, 'moderation' );
my $deleted = _event( 'attachment.deleted', $id );
is_deeply(
    _audit( 'attachment.deleted', $id ),
    [ $user{moderator}, $deleted->[1] ],
    'a deletion is audited under who deleted, with its event\'s correlation id'
);
isnt( $deleted->[1], $uploaded->[1], 'each action draws its own correlation' );

# A row a writer stored under another id, holding this intent's object key,
# before it stopped short of its event.
my $leftover = _intent('leftover');
my $holder   = $ids->uuid;
$dbh->do( $ATTACHMENT_SQL, undef, $holder, $leftover->{object_key},
    $user{owner} );
my $finished = $store->create_intent($leftover);
ok( $finished->{skipped}, 'an intent whose object key is held finishes it' );
is( $finished->{attachment}->get_column('attachment_id'),
    $holder, 'the attachment holding the key' );
is( _event( 'attachment.uploaded', $holder )->[0],
    $holder, 'whose event is written under its own id' );
is( $dbh->selectrow_array( $EVENTS_SQL, undef, $leftover->{attachment_id} ),
    0, 'and none under the id the intent brought' );

my $at   = $clock->now_iso8601;
my $link = $store->link_attachment(
    {
        attachment_id => $holder,
        target_id     => $ids->uuid,
        target_type   => 'post'
    }
);
is( $link->{created_at}, $at, 'a link is answered at the store\'s clock' );
ok(
    $dbh->selectrow_array(
        $LINK_AT_SQL, undef, $at, $link->{attachment_link_id}
    ),
    'and stored at it'
);
my $variant = $store->add_variant(
    {
        attachment_id => $holder,
        byte_size     => $VALID_BYTES,
        media_type    => 'image/webp',
        object_key    => "$leftover->{object_key}/thumbnail",
        variant_type  => 'thumbnail',
    }
);
is( $variant->{created_at}, $at, 'so is a variant' );
ok(
    $dbh->selectrow_array(
        $VARIANT_AT_SQL, undef, $at, $variant->{attachment_variant_id}
    ),
    'in its row too'
);

my $failing = _store( recorder => GPForum::Test::FailingEventRecorder->new );
my $scanned = _intent('scanned');
$store->create_intent($scanned);
$store->mark_uploaded( $scanned->{attachment_id} );
ok(
    !_lives(
        sub {
            $failing->record_scan(
                {
                    actor_id      => 'scanner',
                    attachment_id => $scanned->{attachment_id},
                    scan_status   => 'infected',
                }
            );
        }
    ),
    'a verdict whose event cannot be written fails'
);
is_deeply(
    [ $dbh->selectrow_array( $STATE_SQL, undef, $scanned->{attachment_id} ) ],
    [ 'uploaded', 'pending' ],
    'and leaves the verdict unrecorded'
);

ok(
    !_lives(
        sub {
            $failing->soft_delete( $scanned->{attachment_id},
                $user{moderator}, 'moderation' );
        }
    ),
    'a deletion whose event cannot be written fails'
);
is(
    ( $dbh->selectrow_array( $STATE_SQL, undef, $scanned->{attachment_id} ) )
      [0],
    'uploaded',
    'and leaves the attachment in place'
);

done_testing();

sub _store {
    my (%options) = @_;

    return GPForum::Service::Attachment::Store->new(
        clock      => $clock,
        id_service => $ids,
        schema     => $database->schema,
        %options,
    );
}

sub _user {
    my ($name) = @_;

    my $user_id = $ids->uuid;
    $dbh->do( $USER_SQL, undef, $user_id, $name, ucfirst $name,
        "$name\@example.test" );

    return $user_id;
}

sub _intent {
    my ($name) = @_;

    return GPForum::Service::Attachment::IntentBuilder->new(
        clock      => $clock,
        id_service => $ids,
    )->build_intent(
        {
            byte_size         => $VALID_BYTES,
            checksum          => $name,
            media_type        => 'image/png',
            original_filename => "$name.png",
            owner_user_id     => $user{owner},
        }
    );
}

sub _event {
    my ( $type, $aggregate_id ) = @_;

    return [ $dbh->selectrow_array( $EVENT_SQL, undef, $type, $aggregate_id ) ];
}

sub _audit {
    my ( $action, $target_id ) = @_;

    return [ $dbh->selectrow_array( $AUDIT_SQL, undef, $action, $target_id ) ];
}

sub _lives {
    my ($code) = @_;

    try {
        $code->();
    }
    catch ($error) {
        return 0;
    };

    return 1;
}

1;
