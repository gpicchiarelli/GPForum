# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use File::Temp    qw(tempdir);
use JSON::MaybeXS qw(decode_json encode_json);
use Mojolicious;
use POSIX qw(_exit);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::ScheduledJobs;
use GPForum::Infrastructure::Id;
use GPForum::Service::Attachment::Delivery;
use GPForum::Service::Attachment::Event;
use GPForum::Service::Attachment::FilesystemStorage;
use GPForum::Service::Attachment::IntentBuilder;
use GPForum::Service::Attachment::MediaProcessor;
use GPForum::Service::Attachment::Store;
use GPForum::Service::Attachment::UploadPipeline;
use GPForum::Service::Forum::Readability;
use GPForum::Service::Operations::ScheduledJobs;
use GPForum::Test::Antivirus;
use GPForum::Test::CountingAttachmentStorage;
use GPForum::Test::FixedClock;
use GPForum::Test::PgDatabase;
use GPForum::Test::PostgresHarness;
use GPForum::Test::RacedSchema;
use GPForum::Test::ScriptedId;
use GPForum::Worker::Handler::AttachmentScanning;
use GPForum::Worker::Handler::MediaProcessing;

our $VERSION = '0.001';
our $TODO;

const my $NOW           => '2026-05-23T12:00:00Z';
const my $NOW_EPOCH     => 1_779_537_600;
const my $VALID_BYTES   => 4_096;
const my $VARIANT_BYTES => 512;
const my $PURGE_LIMIT   => 10;
const my $PNG_BYTES     => pack( 'H*', '89504e470d0a1a0a' ) . 'attachment';
const my $SIGNATURE     => 'Eicar-Test-Signature';
const my %TABLE_OF => (
    add_variant     => 'attachment_variants',
    create_intent   => 'attachments',
    link_attachment => 'attachment_links',
);

# The orphan purge takes an intent a day old (Lifecycle::orphan_min_age):
# these are its ages, oldest first, against the clock's $NOW. $A_DAY_AGO is
# the boundary itself, which the purge takes, and $NEARLY_A_DAY a second
# short of it, which the purge leaves.
const my $THREE_DAYS_AGO => '2026-05-20T12:00:00Z';
const my $TWO_DAYS_AGO   => '2026-05-21T12:00:00Z';
const my $A_DAY_AGO      => '2026-05-22T12:00:00Z';
const my $NEARLY_A_DAY   => '2026-05-22T12:00:01Z';
const my $AN_HOUR_AGO    => '2026-05-23T11:00:00Z';
const my $HALF_AN_HOUR   => 1_800;
const my $UNSAFE_KEY     => 'attachments/not a safe key';

# How long a purge in a child process is watched for waiting on a lock.
const my $BLOCK_POLLS        => 100;
const my $BLOCK_POLL_SECONDS => 0.05;
const my $BLOCKED_ON_SQL => join q{ },
  'SELECT count(*) FROM pg_stat_activity',
  'WHERE ? = ANY (pg_blocking_pids(pid))';

# The lock timeout of a purge that must give up on a held row rather than
# wait for it (GPFORUM_DATABASE_LOCK_TIMEOUT_MS).
const my $SHORT_LOCK_TIMEOUT_MS => 200;

# The defects this test found in code outside its reach, each pinned where it
# shows (quality program 5.1).
const my $THREAD_TODO =>
  'DownloadAccess reads hidden_at, a column threads do not have';

const my $USER_SQL => join q{ },
  'INSERT INTO users (id, username, display_name, email_normalized,',
  q{password_hash, status) VALUES (?, ?, ?, ?, 'x', 'active')};
const my $SPACE_SQL => join q{ },
  'INSERT INTO spaces (space_id, slug, title)',
  q{VALUES (?, 'files', 'Files')};
const my $CATEGORY_SQL => join q{ },
  'INSERT INTO categories (category_id, space_id, slug, title, visibility)',
  q{VALUES (?, ?, ?, 'Files', ?)};
const my $THREAD_SQL => join q{ },
  'INSERT INTO threads (thread_id, category_id, author_user_id, title, slug,',
  q{visibility) VALUES (?, ?, ?, 'Files', ?, ?)};
const my $THREAD_STATE_SQL =>
  'UPDATE threads SET moderation_state = ? WHERE thread_id = ?';
const my $POST_SQL => join q{ },
  'INSERT INTO posts (post_id, thread_id, author_user_id, position)',
  'VALUES (?, ?, ?, 1)';
const my $ATTACHMENT_ROW_SQL =>
  'SELECT * FROM attachments WHERE attachment_id = ?';
const my $EVENT_PAYLOAD_SQL => join q{ },
  q{SELECT payload->>'attachment_id' FROM event_log},
  'WHERE aggregate_id = ? AND event_type = ?';
const my $DELETION_SQL => join q{ },
  q{SELECT actor_id, payload->>'reason' FROM event_log},
  q{WHERE aggregate_id = ? AND event_type = 'attachment.deleted'};
const my $OUTBOX_SQL => join q{ },
  'SELECT count(*) FROM outbox_messages',
  'JOIN event_log USING (event_id) WHERE event_log.aggregate_id = ?';
const my $OUTBOX_EVENT_SQL => join q{ },
  q{SELECT outbox_messages.payload->>'event_type' FROM outbox_messages},
  'JOIN event_log USING (event_id) WHERE event_log.aggregate_id = ?';
const my $OUTBOX_DOMAIN_SQL => join q{ },
  q{SELECT outbox_messages.payload->'domain_payload'->>'attachment_id'},
  'FROM outbox_messages JOIN event_log USING (event_id)',
  'WHERE event_log.aggregate_id = ?';
const my $LINK_ID_SQL =>
  'SELECT attachment_link_id FROM attachment_links WHERE attachment_id = ?';
const my $VARIANT_ID_SQL =>
'SELECT attachment_variant_id FROM attachment_variants WHERE attachment_id = ?';

# A timestamp as the clock writes it, whatever zone the server returns it in.
const my $UTC_SQL => join q{ },
  q{SELECT to_char(?::timestamptz AT TIME ZONE 'UTC',},
  q{'YYYY-MM-DD"T"HH24:MI:SS"Z"')};

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# Attachments on PostgreSQL: intents with their event, audit entry and outbox
# message, links to posts and threads, scan verdicts, variants, deletions, the
# upload pipeline and the purge of orphans, and downloads only for those who
# can read the post or thread (ADR 0102). The antivirus stays a double; the
# rows do not. These ran on a fake ORM in t/22, whose rows had a data method
# no DBIx::Class row has: on PostgreSQL a replayed link, variant or thumbnail,
# a deletion and a post's list of files came back without their columns, until
# they were copied with get_columns. And t/22 never served a file through a
# thread, which on PostgreSQL dies.
my $clone = GPForum::Test::PgDatabase->fresh;
my $files = _context($clone);

my $photo = _intents($files);
_intent_atomicity($files);
_intent_id_collisions($files);
_intent_leftover($files);
_links( $files, $photo );
_link_id_races($files);
_scan_states( $files, $photo );
_variants( $files, $photo );
_variant_id_races($files);
_delete_linked($files);
_pipeline($files);
_pipeline_verdicts($files);
_post_listing( $files, _reader_downloads($files) );

# The purge takes from every intent in the database, so each of its cases has
# one to itself.
for my $case ( \&_orphans, \&_orphan_files, \&_orphan_limit, \&_orphan_job,
    \&_orphan_runs_at_once, \&_orphan_link_in_flight, \&_orphan_lock_timeout, )
{
    my $database = GPForum::Test::PgDatabase->fresh;
    $case->( _context($database) );
}

done_testing();

sub _context {
    my ($database) = @_;

    my $ctx = {
        clock  => GPForum::Test::FixedClock->new( epoch => $NOW_EPOCH ),
        dbh    => $database->dbh,
        dsn    => $database->dsn,
        ids    => GPForum::Infrastructure::Id->new,
        schema => $database->schema,
    };
    $ctx->{users} =
      { map { $_ => _user( $ctx, $_ ) } qw(author member uploader other) };
    $ctx->{forum}        = _forum($ctx);
    $ctx->{reader_store} = _store(
        $ctx,
        readability => GPForum::Service::Forum::Readability->new(
            schema => $ctx->{schema}
        )
    );

    return $ctx;
}

sub _user {
    my ( $ctx, $name ) = @_;

    my $id = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $USER_SQL, undef, $id, $name, ucfirst $name,
        "$name\@example.test" );

    return $id;
}

# One space with an open category and a members-only one. The open category
# has a public thread and a private one; each thread has one post, all by the
# author.
sub _forum {
    my ($ctx) = @_;

    my %forum = map { $_ => $ctx->{ids}->uuid }
      qw(space open club thread private_thread club_thread post private_post
      club_post);
    my $dbh    = $ctx->{dbh};
    my $author = $ctx->{users}{author};
    $dbh->do( $SPACE_SQL, undef, $forum{space} );
    $dbh->do( $CATEGORY_SQL, undef, $forum{open}, $forum{space}, 'open',
        'public' );
    $dbh->do( $CATEGORY_SQL, undef, $forum{club}, $forum{space}, 'club',
        'members' );

    for my $thread (
        [ 'thread',         'open', 'public' ],
        [ 'private_thread', 'open', 'private' ],
        [ 'club_thread',    'club', 'public' ],
      )
    {
        my ( $name, $category, $visibility ) = @{$thread};
        $dbh->do( $THREAD_SQL, undef, $forum{$name}, $forum{$category},
            $author, $name, $visibility );
    }
    for my $post (
        [ 'post',         'thread' ],
        [ 'private_post', 'private_thread' ],
        [ 'club_post',    'club_thread' ],
      )
    {
        $dbh->do(
            $POST_SQL, undef,
            $forum{ $post->[0] },
            $forum{ $post->[1] }, $author
        );
    }

    return \%forum;
}

# An intent and the event, audit entry and outbox message it is stored with;
# the same intent again, and again after a look that lost the race, is the
# row already there.
sub _intents {
    my ($ctx) = @_;

    my $intent  = _intent( $ctx, $ctx->{users}{author}, 'photo' );
    my $id      = $intent->{attachment_id};
    my $store   = _store($ctx);
    my $created = $store->create_intent($intent);
    ok( $created->{ok}, 'attachment intent is stored' );

    my $row = _attachment_row( $ctx, $id );
    is( $row->{state},       'intent',  'the row starts in the intent state' );
    is( $row->{scan_status}, 'pending', 'with its scan pending' );
    is(
        $row->{object_key},
        "attachments/$ctx->{users}{author}/$id",
        'under its owner\'s object key'
    );
    is( _utc( $ctx, $row->{created_at} ), $NOW, 'and its creation time' );
    is( _events( $ctx, $id, 'attachment.uploaded' ),
        1, 'upload event is inserted' );
    is( _value( $ctx, $EVENT_PAYLOAD_SQL, $id, 'attachment.uploaded' ),
        $id, 'upload event payload records attachment' );
    is( _audits( $ctx, $id, 'attachment.uploaded' ),
        1, 'upload audit is inserted' );
    is( _value( $ctx, $OUTBOX_SQL, $id ), 1, 'upload outbox row is inserted' );
    is(
        _value( $ctx, $OUTBOX_EVENT_SQL, $id ),
        'attachment.uploaded',
        'outbox payload carries upload event'
    );
    is( _value( $ctx, $OUTBOX_DOMAIN_SQL, $id ),
        $id, 'outbox payload carries domain payload' );

    ok(
        $store->create_intent($intent)->{skipped},
        'already-stored attachment intent is skipped'
    );
    is( _count( $ctx, 'attachments', { attachment_id => $id } ),
        1, 'already-stored intent does not insert another attachment' );
    is( _events( $ctx, $id ),
        1, 'already-stored intent does not insert another event' );

    my ( $raced, $tries ) = _raced(
        $ctx,
        { misses => { Attachment => 1 } },
        create_intent => $intent
    );
    ok( $raced->{skipped},
        'unique attachment intent race reuses the object key' );
    is( $tries, 1, 'unique attachment intent race tries one INSERT' );
    is( _count( $ctx, 'attachments', { attachment_id => $id } ),
        1, 'unique attachment intent race does not insert another row' );
    is( _events( $ctx, $id ),
        1, 'unique attachment intent race does not insert another event' );

    return $id;
}

# The intent and its event share a transaction: when PostgreSQL refuses the
# event, no attachment is left without one.
sub _intent_atomicity {
    my ($ctx) = @_;

    my $intent = _intent( $ctx, $ctx->{users}{author}, 'atomic' );
    my $store  = _store(
        $ctx,
        events => GPForum::Service::Attachment::Event->new(
            id_service =>
              GPForum::Test::ScriptedId->new( next_ids => ['not-a-uuid'] )
        )
    );
    my ( $stored, $tries ) = _inserts(
        $ctx,
        'attachments',
        sub {
            my $created;
            try {
                $created = $store->create_intent($intent);
            }
            catch ($error) {
                $created = undef;
            };
            return $created;
        }
    );
    ok( !$stored, 'an intent whose event PostgreSQL refuses is not stored' );
    is( $tries, 1, 'although its attachment was inserted' );
    is(
        _count(
            $ctx, 'attachments',
            { attachment_id => $intent->{attachment_id} }
        ),
        0,
        'and leaves no attachment row behind'
    );

    return;
}

# An intent whose id another attachment holds is reissued under a fresh id
# and object key: found by the look, or by the primary key PostgreSQL
# enforces when the look lost the race.
sub _intent_id_collisions {
    my ($ctx) = @_;

    my $owner = $ctx->{users}{uploader};
    my $seed  = _attachment(
        $ctx,
        {
            owner_user_id => $ctx->{users}{other},
            scan_status   => 'pending',
            state         => 'intent',
        }
    );
    for my $case (
        [ 'unique attachment id collision', {}, [ 1, 'one INSERT' ] ],
        [
            'unique attachment id race',
            { Attachment => 1 },
            [ 2, 'two INSERTs' ]
        ],
      )
    {
        my ( $label, $misses, $expected ) = @{$case};
        my $intent = {
            %{ _intent( $ctx, $owner, $label ) },
            attachment_id => $seed,
            object_key    => "attachments/$owner/$seed",
        };
        my ( $created, $tries ) =
          _raced( $ctx, { misses => $misses }, create_intent => $intent );
        ok(
            $created->{ok} && !$created->{skipped},
            "$label does not return another attachment"
        );
        is( $tries, $expected->[0], "$label tries $expected->[1]" );
        my $id = $created->{attachment}->get_column('attachment_id');
        ok( GPForum::Infrastructure::Id->is_uuid($id) && $id ne $seed,
            "$label remints the id" );
        is( _attachment_row( $ctx, $id )->{object_key},
            "attachments/$owner/$id", "$label remints the object key" );
        is(
            _attachment_row( $ctx, $seed )->{owner_user_id},
            $ctx->{users}{other},
            "$label leaves the other attachment alone"
        );
    }

    return;
}

# An attachment row whose event, audit entry and outbox message are missing
# is finished by the next attempt at the same intent -- here one whose look
# lost the race.
sub _intent_leftover {
    my ($ctx) = @_;

    my $intent = _intent( $ctx, $ctx->{users}{other}, 'leftover' );
    my $id     = $intent->{attachment_id};
    _attachment(
        $ctx,
        {
            %{$intent}{
                qw(attachment_id byte_size checksum media_type object_key
                  original_filename owner_user_id)
            },
            scan_status => 'pending',
            state       => 'intent',
        }
    );
    my ( $leftover, $tries ) = _raced(
        $ctx,
        { misses => { Attachment => 1 } },
        create_intent => $intent
    );
    ok( $leftover->{skipped},
        'leftover attachment id race reuses this attachment' );
    is( $tries, 1, 'leftover attachment id race tries one INSERT' );
    is( $leftover->{attachment}->get_column('attachment_id'),
        $id, 'leftover attachment id race keeps this attachment' );
    is( _count( $ctx, 'attachments', { attachment_id => $id } ),
        1, 'leftover attachment id race does not insert a second attachment' );
    is( _events( $ctx, $id, 'attachment.uploaded' ),
        1, 'leftover attachment id race inserts the missing event' );
    is( _value( $ctx, $OUTBOX_SQL, $id ),
        1, 'leftover attachment id race inserts the missing outbox row' );
    is( _audits( $ctx, $id, 'attachment.uploaded' ),
        1, 'leftover attachment id race inserts the missing audit row' );

    return;
}

sub _links {
    my ( $ctx, $id ) = @_;

    my $store  = _store($ctx);
    my $target = {
        attachment_id => $id,
        target_id     => $ctx->{forum}{post},
        target_type   => 'post',
    };
    my $link = $store->link_attachment($target);
    is( $link->{attachment_id}, $id,    'attachment link stores attachment' );
    is( $link->{target_type},   'post', 'attachment link stores target type' );
    is( _count( $ctx, 'attachment_links', { attachment_id => $id } ),
        1, 'attachment link row is inserted' );

    ok(
        $store->link_attachment($target)->{idempotent},
        'attachment link create is idempotent'
    );
    is( _count( $ctx, 'attachment_links', { attachment_id => $id } ),
        1, 'idempotent attachment link avoids a second row' );

    my ( $raced, $tries ) = _raced(
        $ctx,
        { misses => { AttachmentLink => 1 } },
        link_attachment => $target
    );
    ok( $raced->{idempotent}, 'unique attachment link race reuses the target' );
    is( $tries, 1, 'unique attachment link race tries one INSERT' );
    is( _count( $ctx, 'attachment_links', { attachment_id => $id } ),
        1, 'unique attachment link race does not insert a second row' );

    return;
}

# A link id another link holds: retried under a fresh id, unless the link
# that holds it is this one.
sub _link_id_races {
    my ($ctx) = @_;

    my $post  = $ctx->{forum}{post};
    my $taken = _link( $ctx, _attachment( $ctx, {} ), $post );
    my $ours  = _attachment( $ctx, {} );
    my ( $retried, $tries ) = _raced(
        $ctx,
        { ids => [$taken] },
        link_attachment =>
          { attachment_id => $ours, target_id => $post, target_type => 'post' }
    );
    ok( !$retried->{idempotent},
        'unique attachment link id collision does not reuse another link' );
    is( $tries, 2, 'unique attachment link id collision tries two INSERTs' );
    ok( $retried->{attachment_link_id} ne $taken,
        'unique attachment link id collision remints the id' );
    is( $retried->{attachment_id},
        $ours, 'unique attachment link id collision keeps this attachment' );
    is(
        _value( $ctx, $LINK_ID_SQL, $ours ),
        $retried->{attachment_link_id},
        'unique attachment link id collision inserts one retried link'
    );

    my $kept_file = _attachment( $ctx, {} );
    my $kept      = _link( $ctx, $kept_file, $post );
    my ( $replayed, $kept_tries ) = _raced(
        $ctx,
        { ids => [$kept], misses => { AttachmentLink => 1 } },
        link_attachment => {
            attachment_id => $kept_file,
            target_id     => $post,
            target_type   => 'post'
        }
    );
    ok( $replayed->{idempotent},
        'leftover attachment link id race reuses this link' );
    is( $kept_tries, 1, 'leftover attachment link id race tries one INSERT' );
    is( _value( $ctx, $LINK_ID_SQL, $kept_file ),
        $kept, 'leftover attachment link id race keeps this link' );
    is( _count( $ctx, 'attachment_links', { attachment_id => $kept_file } ),
        1, 'leftover attachment link id race does not insert a second link' );
    is( $replayed->{attachment_link_id},
        $kept, 'leftover attachment link id race reports the link it kept' );
    is( $replayed->{attachment_id},
        $kept_file, 'leftover attachment link id race keeps this attachment' );

    return;
}

# Pending, clean, infected: only a clean, available file is ever served.
sub _scan_states {
    my ( $ctx, $id ) = @_;

    my $store = _store($ctx);
    my $owner = $ctx->{users}{author};
    is( _download( $store, $id, $owner ),
        'not_found', 'an intent is not downloadable, even by its owner' );

    my $uploaded = $store->mark_uploaded($id);
    is( $uploaded->{state}, 'uploaded', 'attachment can be marked uploaded' );
    is( $uploaded->{uploaded_at}, $NOW, 'uploaded timestamp is stored' );
    is( _utc( $ctx, _attachment_row( $ctx, $id )->{uploaded_at} ),
        $NOW, 'as PostgreSQL keeps it' );
    ok(
        $store->mark_uploaded($id)->{idempotent},
        'marking it uploaded again is a replay'
    );
    is( _download( $store, $id, $owner ),
        'not_found', 'a pending upload is not downloadable' );

    my $clean = $store->record_scan(
        { attachment_id => $id, actor_id => 'scanner', scan_status => 'clean' }
    );
    is( $clean->{state},       'available', 'clean scan makes it available' );
    is( $clean->{scan_status}, 'clean',     'clean scan status is stored' );
    is( _attachment_row( $ctx, $id )->{state},
        'available', 'and PostgreSQL holds it' );
    is( _events( $ctx, $id, 'attachment.scanned' ),
        1, 'clean scan records scanned event' );
    my $download =
      $store->download_for( { attachment_id => $id, viewer_user_id => undef } );
    ok( $download->{ok}, 'public linked clean attachment can be downloaded' );
    is( $download->{object_key},
        "attachments/$owner/$id", 'download exposes storage object key' );

    my $quarantined = $store->record_scan(
        {
            attachment_id => $id,
            actor_id      => 'scanner',
            scan_status   => 'infected',
            reason        => 'malware',
        }
    );
    is( $quarantined->{state},
        'quarantined', 'infected scan quarantines attachment' );
    is( $quarantined->{quarantined_at}, $NOW,
        'quarantine timestamp is stored' );
    is( _utc( $ctx, _attachment_row( $ctx, $id )->{quarantined_at} ),
        $NOW, 'as PostgreSQL keeps it' );
    is( _events( $ctx, $id, 'attachment.quarantined' ),
        1, 'infected scan records quarantine event' );
    is( _download( $store, $id, $owner ),
        'not_found', 'quarantined attachment is not downloadable' );

    return;
}

sub _variants {
    my ( $ctx, $id ) = @_;

    my $store = _store($ctx);
    my $thumb = _thumbnail( $id, "attachments/$ctx->{users}{author}/$id" );
    is( $store->add_variant($thumb)->{variant_type},
        'thumbnail', 'variant stores variant type' );
    is( _count( $ctx, 'attachment_variants', { attachment_id => $id } ),
        1, 'variant row is inserted' );
    ok(
        $store->add_variant($thumb)->{idempotent},
        'variant creation is idempotent'
    );
    is( _count( $ctx, 'attachment_variants', { attachment_id => $id } ),
        1, 'idempotent variant creation avoids duplicates' );
    my ( $raced, $tries ) = _raced(
        $ctx,
        { misses => { AttachmentVariant => 2 } },
        add_variant => $thumb
    );
    ok( $raced->{idempotent},
        'unique attachment variant race reuses the variant type' );
    is( $tries, 1, 'unique attachment variant race tries one INSERT' );
    is( _count( $ctx, 'attachment_variants', { attachment_id => $id } ),
        1, 'unique attachment variant race does not insert a second row' );

    my $preview = { %{$thumb}, variant_type => 'preview' };
    ok(
        $store->add_variant($preview)->{idempotent},
        'variant object key reuse is idempotent'
    );
    is( _count( $ctx, 'attachment_variants', { attachment_id => $id } ),
        1, 'variant object key reuse does not insert another row' );
    my ( $raced_key, $key_tries ) = _raced(
        $ctx,
        { misses => { AttachmentVariant => 2 } },
        add_variant => $preview
    );
    ok( $raced_key->{idempotent},
        'unique variant object-key race reuses the stored blob' );
    is( $key_tries, 1, 'unique variant object-key race tries one INSERT' );
    is( _count( $ctx, 'attachment_variants', { attachment_id => $id } ),
        1, 'unique variant object-key race does not insert a second row' );

    return;
}

# A variant id another variant holds: retried under a fresh id, unless the
# variant that holds it is this one.
sub _variant_id_races {
    my ($ctx) = @_;

    my $taken = _variant( $ctx, _attachment( $ctx, {} ) );
    my $ours  = _attachment( $ctx, {} );
    my ( $retried, $tries ) = _raced(
        $ctx,
        { ids => [$taken] },
        add_variant => _thumbnail( $ours, "variants/$ours" )
    );
    ok( !$retried->{idempotent},
        'unique variant id collision does not reuse another variant' );
    is( $tries, 2, 'unique variant id collision tries two INSERTs' );
    ok(
        $retried->{attachment_variant_id} ne $taken,
        'unique variant id collision remints the id'
    );
    is( $retried->{attachment_id},
        $ours, 'unique variant id collision keeps this attachment' );
    is(
        _value( $ctx, $VARIANT_ID_SQL, $ours ),
        $retried->{attachment_variant_id},
        'unique variant id collision inserts one retried variant'
    );

    my $kept_file = _attachment( $ctx, {} );
    my $kept      = _variant( $ctx, $kept_file );
    my ( $replayed, $kept_tries ) = _raced(
        $ctx,
        { ids => [$kept], misses => { AttachmentVariant => 2 } },
        add_variant => _thumbnail( $kept_file, "variants/$kept_file" )
    );
    ok( $replayed->{idempotent},
        'leftover variant id race reuses this variant' );
    is( $kept_tries, 1, 'leftover variant id race tries one INSERT' );
    is( _value( $ctx, $VARIANT_ID_SQL, $kept_file ),
        $kept, 'leftover variant id race keeps this variant' );
    is(
        _count( $ctx, 'attachment_variants', { attachment_id => $kept_file } ),
        1,
        'leftover variant id race does not insert a second variant'
    );
    is( $replayed->{attachment_variant_id},
        $kept, 'leftover variant id race reports the variant it kept' );
    is( $replayed->{attachment_id},
        $kept_file, 'leftover variant id race keeps this attachment' );

    return;
}

sub _delete_linked {
    my ($ctx) = @_;

    my $id = _attachment( $ctx, {} );
    _link( $ctx, $id, $ctx->{forum}{post} );
    my $store = _store($ctx);
    my $input = {
        actor_id      => $ctx->{users}{author},
        attachment_id => $id,
        target_id     => $ctx->{forum}{post},
        target_type   => 'post',
    };

    my $deleted = $store->delete_linked($input);
    ok( $deleted->{ok}, 'delete_linked removes a linked attachment' );
    is( _attachment_row( $ctx, $id )->{state},
        'deleted', 'delete_linked soft-deletes the linked attachment' );
    is( _utc( $ctx, _attachment_row( $ctx, $id )->{deleted_at} ),
        $NOW, 'and stamps its deletion' );
    ok( !$deleted->{idempotent},
        'delete_linked is not a replay on the first delete' );
    is( _events( $ctx, $id, 'attachment.deleted' ),
        1, 'delete_linked records the deletion event' );
    is( $deleted->{attachment}{attachment_id},
        $id, 'delete_linked reports the attachment it deleted' );
    is( $deleted->{attachment}{state}, 'deleted', 'as deleted' );
    is( _audits( $ctx, $id, 'attachment.deleted' ),
        1, 'and audits the deletion under its id' );

    my $replay = $store->delete_linked($input);
    ok( $replay->{ok}, 'delete_linked replays an already-deleted row' );
    ok( $replay->{idempotent},
        'delete_linked marks an already-deleted row as idempotent' );
    is( _events( $ctx, $id, 'attachment.deleted' ),
        1, 'a replayed delete records nothing more' );
    is( $replay->{attachment}{attachment_id},
        $id, 'a replayed delete reports the attachment it found deleted' );
    is( $replay->{attachment}{state}, 'deleted', 'in the state it found it' );

    my $unlinked =
      $store->delete_linked( { %{$input}, target_id => $ctx->{ids}->uuid } );
    ok( !$unlinked->{ok}, 'delete_linked rejects a missing post link' );
    is( $unlinked->{error}, 'not_found',
        'delete_linked names a missing post link' );

    return;
}

sub _pipeline {
    my ($ctx) = @_;

    my $storage = GPForum::Service::Attachment::FilesystemStorage->new(
        root => tempdir( CLEANUP => 1 ) );
    my $store    = _store($ctx);
    my $uploaded = GPForum::Service::Attachment::UploadPipeline->new(
        intent_builder => GPForum::Service::Attachment::IntentBuilder->new(
            clock      => $ctx->{clock},
            id_service => $ctx->{ids},
        ),
        storage => $storage,
        store   => $store,
    )->upload_and_link( _upload( $ctx, 'text/plain' ) );
    my $id = $uploaded->{attachment}{attachment_id};
    ok( $uploaded->{ok}, 'upload pipeline accepts valid file content' );
    is( $uploaded->{attachment}{media_type},
        'image/png', 'upload pipeline uses sniffed media type' );
    is( $uploaded->{attachment}{state},
        'available',
        'upload pipeline makes locally validated attachment available' );
    is( _attachment_row( $ctx, $id )->{scan_engine},
        'format-check', 'on the format check alone, as its row says' );
    ok(
        $storage->exists_object( $uploaded->{attachment}{object_key} ),
        'upload pipeline writes object to filesystem storage'
    );
    is(
        _count(
            $ctx,
            'attachment_links',
            {
                attachment_id => $id,
                target_id     => $ctx->{forum}{post},
                target_type   => 'post'
            }
        ),
        1,
        'upload pipeline links attachment to post'
    );

    _delivery( $store, $storage, $id );
    _media( $ctx, $store, $storage, $id );

    return;
}

sub _delivery {
    my ( $store, $storage, $id ) = @_;

    my $delivered = GPForum::Service::Attachment::Delivery->new(
        storage => $storage,
        store   => $store,
    )->download( { attachment_id => $id, viewer_user_id => undef } );
    ok( $delivered->{ok}, 'delivery returns public attachment' );

    # Delivery used to read the whole object into a scalar here. It now names
    # the object so the caller can stream it, and the bytes must never be
    # materialized on this path -- that is the whole point of the change.
    ok( !exists $delivered->{content},
        'delivery does not read the object into memory' );
    ok( defined $delivered->{object_path}, 'delivery names the stored object' );
    ok( -e $delivered->{object_path}, 'the named object path exists on disk' );
    is( _slurp_bytes( $delivered->{object_path} ),
        $PNG_BYTES, 'the named object holds the stored bytes' );

    # The claim is that an authorized download reads nothing. Counting the
    # reads is the only way to hold it: an assertion about the returned hash
    # would still pass if the bytes were read and then discarded.
    my $counted_storage =
      GPForum::Test::CountingAttachmentStorage->new( inner => $storage );
    my $counted = GPForum::Service::Attachment::Delivery->new(
        storage => $counted_storage,
        store   => $store,
    )->download( { attachment_id => $id, viewer_user_id => undef } );
    ok( $counted->{ok}, 'counted delivery authorizes the download' );
    is( scalar @{ $counted_storage->reads },
        0, 'an authorized download reads no bytes from storage' );

    return;
}

sub _media {
    my ( $ctx, $store, $storage, $id ) = @_;

    my $media_storage =
      GPForum::Test::CountingAttachmentStorage->new( inner => $storage );
    my $processor = GPForum::Service::Attachment::MediaProcessor->new(
        storage => $media_storage,
        store   => $store,
    );
    my $processed = $processor->process($id);
    ok( $processed->{ok}, 'media processor handles image attachment' );
    is( $processed->{variant}{variant_type},
        'thumbnail', 'media processor creates thumbnail variant' );
    is( scalar @{ $media_storage->reads },
        1, 'media processor reads the original object once' );
    my $replayed = $processor->process($id);
    ok( $replayed->{skipped},
        'already-applied thumbnail skip does not reread storage' );
    ok(
        $replayed->{variant}{idempotent},
        'media processor retry is idempotent'
    );
    is( $replayed->{variant}{variant_type},
        'thumbnail', 'and names the thumbnail it kept' );
    is(
        $replayed->{variant}{attachment_variant_id},
        $processed->{variant}{attachment_variant_id},
        'the one it wrote the first time'
    );
    is( scalar @{ $media_storage->reads },
        1, 'already-applied thumbnail does not reread the object' );
    is( _count( $ctx, 'attachment_variants', { attachment_id => $id } ),
        1, 'media processor retry avoids duplicate variants' );

    my $scanning_worker = GPForum::Worker::Handler::AttachmentScanning->new(
        storage =>
          GPForum::Test::CountingAttachmentStorage->new( inner => $storage ),
        store => $store,
    );
    my $events_before = _events( $ctx, $id );
    my $scan_retry =
      $scanning_worker->handle( _event( $ctx, $id, 'attachment.uploaded' ) );
    ok( $scan_retry->{scan}{idempotent}, 'scanner retry is idempotent' );
    is( scalar @{ $scanning_worker->storage->reads },
        0, 'already-scanned attachment does not reread the object' );
    is( _events( $ctx, $id ),
        $events_before, 'scanner retry avoids duplicate scan events' );

    my $media_retry =
      GPForum::Worker::Handler::MediaProcessing->new( processor => $processor )
      ->handle(
        {
            %{ _event( $ctx, $id, 'attachment.scanned' ) },
            scan_status => 'clean'
        }
      );
    ok(
        $media_retry->{media}{variant}{idempotent},
        'media worker retry is idempotent'
    );

    return;
}

# The verdict an upload reaches by itself, and what a reader gets for it: a
# scanner that cannot answer within the request leaves the upload pending and
# unserved until the attachment worker decides it; clean is served; infected
# is quarantined with its signature.
sub _pipeline_verdicts {
    my ($ctx) = @_;

    my $storage = GPForum::Service::Attachment::FilesystemStorage->new(
        root => tempdir( CLEANUP => 1 ) );
    my $store = _store($ctx);
    my %uploaded;
    for my $case (
        [
            'pending',
            GPForum::Test::Antivirus->new( immediate => 0 ),
            [ 'uploaded', 'pending', undef, 'not_found' ],
        ],
        [
            'clean',
            GPForum::Test::Antivirus->new,
            [ 'available', 'clean', undef, 'ok' ],
        ],
        [
            'infected',
            GPForum::Test::Antivirus->new( detects => qr/attachment/msx ),
            [ 'quarantined', 'infected', $SIGNATURE, 'not_found' ],
        ],
      )
    {
        my ( $label, $antivirus, $expected ) = @{$case};
        my $id = GPForum::Service::Attachment::UploadPipeline->new(
            antivirus => $antivirus,
            storage   => $storage,
            store     => $store,
        )->upload_and_link( _upload( $ctx, 'image/png' ) )
          ->{attachment}{attachment_id};
        my $row = _attachment_row( $ctx, $id );
        is_deeply(
            [
                @{$row}{qw(state scan_status scan_signature)},
                _download( $store, $id, undef )
            ],
            $expected,
            "the $label upload: its state, scan, signature and download"
        );
        $uploaded{$label} = $id;
    }

    GPForum::Worker::Handler::AttachmentScanning->new(
        antivirus => GPForum::Test::Antivirus->new,
        storage   => $storage,
        store     => $store,
    )->handle( _event( $ctx, $uploaded{pending}, 'attachment.uploaded' ) );
    is( _download( $store, $uploaded{pending}, undef ),
        'ok',
        'the attachment worker decides a pending upload, and it is served' );

    return;
}

# ADR 0102: a file on a post or thread is served to those who can read it,
# and to its uploader. Returns the file on the members-only post.
sub _reader_downloads {
    my ($ctx) = @_;

    my $forum     = $ctx->{forum};
    my $club_file = _attachment( $ctx, {} );
    _link( $ctx, $club_file, $forum->{club_post} );
    _downloads_as(
        $ctx, $club_file,
        { anonymous => 'forbidden', member => 'ok' },
        'a members-only post'
    );

    my $uploaded =
      _attachment( $ctx, { owner_user_id => $ctx->{users}{uploader} } );
    _link( $ctx, $uploaded, $forum->{private_post} );
    _downloads_as(
        $ctx,
        $uploaded,
        {
            anonymous => 'forbidden',
            author    => 'ok',
            member    => 'forbidden',
            uploader  => 'ok',
        },
        'a post in a private thread'
    );

    my $thread_file = _attachment( $ctx, {} );
    my $link        = $ctx->{reader_store}->link_attachment(
        {
            attachment_id => $thread_file,
            target_id     => $forum->{club_thread},
            target_type   => 'thread',
        }
    );
    is( $link->{target_type}, 'thread', 'an attachment links to a thread' );
    is(
        _count(
            $ctx, 'attachment_links',
            { attachment_id => $thread_file, target_type => 'thread' }
        ),
        1,
        'in one row'
    );
    {
        local $TODO = $THREAD_TODO;
        _downloads_as(
            $ctx, $thread_file,
            { anonymous => 'forbidden', member => 'ok' },
            'a members-only thread'
        );
    }
    _moderated_thread( $ctx, $forum->{thread} );

    return $club_file;
}

# A locked thread is still read, so its files are served; a hidden one is
# not, to anyone -- the one branch of the access check only threads take.
sub _moderated_thread {
    my ( $ctx, $thread ) = @_;

    my $file = _attachment( $ctx, {} );
    $ctx->{reader_store}->link_attachment(
        {
            attachment_id => $file,
            target_id     => $thread,
            target_type   => 'thread'
        }
    );
    for my $case (
        [ 'locked', { anonymous => 'ok' } ],
        [ 'hidden', { anonymous => 'forbidden', author => 'forbidden' } ],
      )
    {
        my ( $state, $expected ) = @{$case};
        $ctx->{dbh}->do( $THREAD_STATE_SQL, undef, $state, $thread );
        local $TODO = $THREAD_TODO;
        _downloads_as( $ctx, $file, $expected, "a $state thread" );
    }
    $ctx->{dbh}->do( $THREAD_STATE_SQL, undef, 'visible', $thread );

    return;
}

# The files a thread page lists under each post: the ones the reader may
# download.
sub _post_listing {
    my ( $ctx, $club_file ) = @_;

    my $post  = $ctx->{forum}{club_post};
    my $store = $ctx->{reader_store};
    my $listed =
      $store->attachments_for_posts( [$post],
        { viewer_user_id => $ctx->{users}{member} } );
    is( scalar @{ $listed->{$post} || [] },
        1, 'a members-only post lists its file to a member' );
    is_deeply( $store->attachments_for_posts( [$post], {} ),
        {}, 'and nothing to a visitor' );
    is( $listed->{$post}[0]{attachment_id},     $club_file,   'by its id' );
    is( $listed->{$post}[0]{original_filename}, 'seeded.txt', 'and its name' );

    return;
}

# The purge of orphans: intents nobody linked and a day old, oldest first and
# up to the limit, soft-deleted with an event in their owner's name, or in the
# name and for the reason the run gives. A linked intent, a served file and an
# intent younger than a day -- an upload that may still be in flight -- stay.
# An upload that crashed after writing its file leaves an orphan whose
# stored object goes with it.
sub _orphans {
    my ($ctx) = @_;

    my $oldest  = _intent_row( $ctx, $TWO_DAYS_AGO );
    my $orphan  = _intent_row( $ctx, $A_DAY_AGO );
    my $linked  = _intent_row( $ctx, $A_DAY_AGO );
    my $served  = _attachment( $ctx, { created_at => $TWO_DAYS_AGO } );
    my $young   = _intent_row( $ctx, $AN_HOUR_AGO );
    my $nearly  = _intent_row( $ctx, $NEARLY_A_DAY );
    my $storage = _storage();
    my $store   = _store( $ctx, storage => $storage );
    _link( $ctx, $linked, $ctx->{forum}{post} );

    is( scalar @{ $store->cleanup_orphans( { limit => 1 } )->{deleted} },
        1, 'the purge stops at its limit' );
    is( _attachment_row( $ctx, $oldest )->{state},
        'deleted', 'and takes the oldest orphan first' );
    is( _attachment_row( $ctx, $orphan )->{state},
        'intent', 'leaving the next for the following run' );

    my $cleanup = $store->cleanup_orphans( { limit => $PURGE_LIMIT } );
    is( scalar @{ $cleanup->{deleted} }, 1, 'cleanup deletes one orphan' );
    is( $cleanup->{deleted}[0]{attachment_id},
        $orphan, 'and reports the attachment it deleted' );
    is( _attachment_row( $ctx, $orphan )->{state},
        'deleted', 'cleanup soft-deletes orphan' );
    is( _attachment_row( $ctx, $linked )->{state},
        'intent', 'cleanup keeps linked attachment' );
    is( _attachment_row( $ctx, $served )->{state},
        'available', 'cleanup leaves a served file alone' );
    is( _attachment_row( $ctx, $young )->{state},
        'intent', 'and an intent younger than a day, which may be in flight' );
    is( _attachment_row( $ctx, $nearly )->{state},
        'intent', 'even one a second short of the day' );
    is_deeply(
        _deletion( $ctx, $orphan ),
        [ $ctx->{users}{author}, 'orphan cleanup' ],
        'the purge records the deletion in the owner\'s name, as orphan cleanup'
    );

    my $swept = _intent_row( $ctx, $TWO_DAYS_AGO );
    $store->cleanup_orphans(
        {
            actor_id => $ctx->{users}{other},
            limit    => $PURGE_LIMIT,
            reason   => 'operator sweep',
        }
    );
    is_deeply(
        _deletion( $ctx, $swept ),
        [ $ctx->{users}{other}, 'operator sweep' ],
        'a purge run for someone records their name and reason instead'
    );

    $store->cleanup_orphans( { limit => $PURGE_LIMIT, min_age => 0 } );
    is_deeply(
        [ map { _attachment_row( $ctx, $_ )->{state} } $nearly, $young ],
        [ 'intent',                                             'intent' ],
        'a minimum age of zero is not taken: the day stands'
    );
    $store->cleanup_orphans(
        { limit => $PURGE_LIMIT, min_age => $HALF_AN_HOUR } );
    is( _attachment_row( $ctx, $young )->{state},
        'deleted', 'a run given a shorter minimum age takes the hour-old one' );

    my $crashed = _stored_intent( $ctx, $storage, $TWO_DAYS_AGO );
    my $key     = _attachment_row( $ctx, $crashed )->{object_key};
    $store->cleanup_orphans( { limit => $PURGE_LIMIT } );
    is( _attachment_row( $ctx, $crashed )->{state},
        'deleted', 'the purge takes a crashed upload\'s orphan' );
    ok( !$storage->exists_object($key), 'and removes its stored object' );

    return;
}

# What the purge does to the stored files: the original's and its variants'
# go before the row, a run that finds them gone already purges the row all
# the same, and a file the storage will not remove leaves its orphan for the
# next run while the others are purged. Without a storage it purges nothing,
# rather than delete rows whose files would then stay for good.
sub _orphan_files {
    my ($ctx) = @_;

    my $storage   = _storage();
    my $abandoned = _stored_intent( $ctx, $storage, $A_DAY_AGO );
    my $original  = _attachment_row( $ctx, $abandoned )->{object_key};
    _variant( $ctx, $abandoned );
    my $thumbnail = "variants/$abandoned/thumb";
    $storage->write_object( $thumbnail, $PNG_BYTES );
    my $served = _attachment( $ctx, { created_at => $TWO_DAYS_AGO } );
    $storage->write_object( _attachment_row( $ctx, $served )->{object_key},
        $PNG_BYTES );
    my $young = _stored_intent( $ctx, $storage, $AN_HOUR_AGO );

    my $refused = _store($ctx)->cleanup_orphans( { limit => $PURGE_LIMIT } );
    is_deeply(
        $refused,
        { deleted => [], ok => 1, skipped => 'no attachment storage' },
        'a purge without a storage says so'
    );
    is( _attachment_row( $ctx, $abandoned )->{state},
        'intent', 'and leaves the orphan for a run that can remove its files' );

    my $store   = _store( $ctx, storage => $storage );
    my $cleanup = $store->cleanup_orphans( { limit => $PURGE_LIMIT } );
    is_deeply(
        [
            $cleanup->{ok}, map { $_->{attachment_id} } @{ $cleanup->{deleted} }
        ],
        [ 1, $abandoned ],
        'the purge deletes the abandoned intent'
    );
    is( _attachment_row( $ctx, $abandoned )->{state},
        'deleted', 'soft-deleting its row' );
    ok( !$storage->exists_object($original),  'removes its stored object' );
    ok( !$storage->exists_object($thumbnail), 'and the object of its variant' );
    is(
        _count( $ctx, 'attachment_variants', { attachment_id => $abandoned } ),
        1,
        'whose row stays with the deleted attachment'
    );
    ok(
        $storage->exists_object(
            _attachment_row( $ctx, $served )->{object_key}
        ),
        'a served file keeps its object'
    );
    ok(
        $storage->exists_object(
            _attachment_row( $ctx, $young )->{object_key}
        ),
        'and so does an upload that may be in flight'
    );
    is_deeply(
        $store->cleanup_orphans( { limit => $PURGE_LIMIT } ),
        { deleted => [], ok => 1 },
        'a second run finds nothing to purge'
    );

    # A run that removed the files and died before the delete.
    my $half_done = _intent_row( $ctx, $A_DAY_AGO );
    is(
        scalar
          @{ $store->cleanup_orphans( { limit => $PURGE_LIMIT } )->{deleted} },
        1,
        'an orphan whose files are already gone is purged'
    );
    is( _attachment_row( $ctx, $half_done )->{state},
        'deleted', 'its row deleted all the same' );

    my $stuck = _attachment(
        $ctx,
        {
            created_at  => $TWO_DAYS_AGO,
            object_key  => $UNSAFE_KEY,
            scan_status => 'pending',
            state       => 'intent',
        }
    );
    my $next    = _stored_intent( $ctx, $storage, $A_DAY_AGO );
    my $partial = $store->cleanup_orphans( { limit => $PURGE_LIMIT } );
    is( $partial->{ok}, 0, 'a file the storage will not remove fails the run' );
    like(
        join( qq{\n}, @{ $partial->{errors} || [] } ),
qr/\A \Q$stuck\E: [ ] attachment [ ] object [ ] key [ ] is [ ] unsafe \z/msx,
        'naming the orphan and why'
    );
    is( _attachment_row( $ctx, $stuck )->{state},
        'intent', 'which stays for the next run' );
    is_deeply( [ map { $_->{attachment_id} } @{ $partial->{deleted} } ],
        [$next], 'while the orphan after it is purged' );
    ok(
        !$storage->exists_object(
            _attachment_row( $ctx, $next )->{object_key}
        ),
        'with its file'
    );

    return;
}

# The limit counts orphans: linked intents at the head of the queue used to
# fill it, and kept every run from reaching the orphan behind them.
sub _orphan_limit {
    my ($ctx) = @_;

    for ( 1 .. 2 ) {
        _link( $ctx, _intent_row( $ctx, $THREE_DAYS_AGO ),
            $ctx->{forum}{post} );
    }
    my $orphan = _intent_row( $ctx, $A_DAY_AGO );
    my $cleanup =
      _store( $ctx, storage => _storage() )->cleanup_orphans( { limit => 2 } );
    is_deeply( [ map { $_->{attachment_id} } @{ $cleanup->{deleted} } ],
        [$orphan], 'linked intents ahead of an orphan do not use the limit' );
    is( _attachment_row( $ctx, $orphan )->{state},
        'deleted', 'and the orphan is purged' );

    return;
}

# The scheduled job, as the timer runs it: the command takes its runner from
# the application, whose attachment store is built without the storage, and
# lends it the application's -- without it the purge removed nothing and said
# so. The orphan's row and its file go, and the summary line counts it.
sub _orphan_job {
    my ($ctx) = @_;

    my $storage     = _storage();
    my $orphan      = _stored_intent( $ctx, $storage, $A_DAY_AGO );
    my $key         = _attachment_row( $ctx, $orphan )->{object_key};
    my $application = Mojolicious->new;
    $application->log->level('fatal');
    $application->helper( gp_attachment_storage => sub { return $storage; } );
    $application->helper(
        gp_scheduled_jobs => sub {
            return GPForum::Service::Operations::ScheduledJobs->new(
                attachment_store => _store($ctx) );
        }
    );

    my $summary = q{};
    open my $output, '>', \$summary or croak 'capture';
    my $exit = GPForum::Command::ScheduledJobs->new(
        app    => $application,
        output => $output,
    )->run( '--job', 'attachments', '--limit', $PURGE_LIMIT );
    close $output or croak 'close capture';
    is( $exit, 0, 'the scheduled orphan purge succeeds' );
    is(
        $summary,
        "scheduled_jobs ok=1 attachments=1\n",
        'and counts the orphan it purged'
    );
    is( _attachment_row( $ctx, $orphan )->{state},
        'deleted', 'whose row it deleted' );
    ok( !$storage->exists_object($key), 'and whose file it removed' );

    return;
}

# Two runs at once: the first has deleted the orphan and not yet committed.
# The second, which read the orphan among its candidates, waits on the row's
# lock, finds it deleted once the first commits, and leaves it. Without the
# lock, or without asking again once it is held, it deleted the row a second
# time and recorded a second deletion.
sub _orphan_runs_at_once {
    my ($ctx) = @_;

    my $storage = _storage();
    my $orphan  = _stored_intent( $ctx, $storage, $A_DAY_AGO );
    my $race    = _purge_while_held(
        $ctx, $storage,
        sub {
            my ($holder) = @_;
            return _store( $ctx, schema => $holder, storage => $storage )
              ->cleanup_orphans( { limit => $PURGE_LIMIT } );
        }
    );

    is_deeply( [ map { $_->{attachment_id} } @{ $race->{held}{deleted} } ],
        [$orphan], 'the first run deletes the orphan' );
    ok( $race->{waited}, 'the second waits on its lock' );
    is_deeply(
        $race->{outcome}{result},
        { deleted => [], ok => 1 },
        'and, once the first commits, finds it deleted and leaves it'
    ) or diag( $race->{outcome}{error} // 'no error' );
    is( _events( $ctx, $orphan, 'attachment.deleted' ),
        1, 'so the orphan is deleted once' );

    return;
}

# A link in flight -- its transaction open, its foreign-key check holding the
# orphan's row -- holds the purge off: the purge waits on the row's lock
# before it removes a file, and once the link commits the attachment is no
# orphan and keeps its file. Without the lock, the purge removed the file of
# the attachment being linked.
sub _orphan_link_in_flight {
    my ($ctx) = @_;

    my $storage = _storage();
    my $linked  = _stored_intent( $ctx, $storage, $A_DAY_AGO );
    my $race    = _purge_while_held(
        $ctx, $storage,
        sub {
            my ($holder) = @_;
            return _link( { dbh => $holder->storage->dbh, ids => $ctx->{ids} },
                $linked, $ctx->{forum}{post} );
        }
    );

    ok( $race->{waited}, 'a purge waits on a link in flight' );
    is_deeply(
        $race->{outcome}{result},
        { deleted => [], ok => 1 },
        'and, once it commits, leaves the attachment'
    ) or diag( $race->{outcome}{error} // 'no error' );
    is( _attachment_row( $ctx, $linked )->{state},
        'intent', 'whose row stays' );
    ok(
        $storage->exists_object(
            _attachment_row( $ctx, $linked )->{object_key}
        ),
        'and whose file stays'
    );

    return;
}

# A row held past the lock timeout -- a link whose transaction stays open --
# fails its orphan alone: the purge gives up on it, reports it, and goes on to
# the orphan behind it; the held one keeps its row and its file, and the next
# run, the link rolled back, purges it.
sub _orphan_lock_timeout {
    my ($ctx) = @_;

    my $storage = _storage();
    my $held    = _stored_intent( $ctx, $storage, $TWO_DAYS_AGO );
    my $next    = _stored_intent( $ctx, $storage, $A_DAY_AGO );
    my $holder  = _connect_schema($ctx);
    $holder->txn_begin;
    _link( { dbh => $holder->storage->dbh, ids => $ctx->{ids} },
        $held, $ctx->{forum}{post} );

    my $purger = do {
        local $ENV{GPFORUM_DATABASE_LOCK_TIMEOUT_MS} = $SHORT_LOCK_TIMEOUT_MS;
        _connect_schema($ctx);
    };
    my $store   = _store( $ctx, schema => $purger, storage => $storage );
    my $cleanup = $store->cleanup_orphans( { limit => $PURGE_LIMIT } );
    $holder->txn_rollback;
    $holder->storage->disconnect;

    is( $cleanup->{ok}, 0, 'a row held past the lock timeout fails the run' );
    like(
        join( qq{\n}, @{ $cleanup->{errors} || [] } ),
        qr/\A \Q$held\E: [ ] [^\n]* lock [ ] timeout [^\n]* \z/msx,
        'naming the orphan and why'
    );
    is_deeply( [ map { $_->{attachment_id} } @{ $cleanup->{deleted} } ],
        [$next], 'and purges the orphan behind it' );
    is( _attachment_row( $ctx, $held )->{state},
        'intent', 'the held orphan keeps its row' );
    ok(
        $storage->exists_object( _attachment_row( $ctx, $held )->{object_key} ),
        'and its file'
    );
    is_deeply(
        [
            map { $_->{attachment_id} } @{
                $store->cleanup_orphans( { limit => $PURGE_LIMIT } )->{deleted}
            }
        ],
        [$held],
        'which the next run purges'
    );
    $purger->storage->disconnect;

    return;
}

# $hold runs in a transaction on a second connection, left open; a purge runs
# in a child process on a third, and the holder commits once the purge waits
# on it, or once it has given up seeing it wait. Returns what $hold returned,
# whether the purge waited, and the purge's outcome.
sub _purge_while_held {
    my ( $ctx, $storage, $hold ) = @_;

    my $holder = _connect_schema($ctx);
    $holder->txn_begin;
    my $held = $hold->($holder);
    my ($holder_pid) =
      $holder->storage->dbh->selectrow_array('SELECT pg_backend_pid()');

    my $purge = _spawn_worker(
        sub {
            return _store(
                $ctx,
                schema  => _connect_schema($ctx),
                storage => $storage
            )->cleanup_orphans( { limit => $PURGE_LIMIT } );
        }
    );
    my $waited = _await_blocked_on( $ctx->{dbh}, $holder_pid );
    $holder->txn_commit;
    $holder->storage->disconnect;

    return {
        held    => $held,
        outcome => _collect_worker($purge),
        waited  => $waited,
    };
}

sub _connect_schema {
    my ($ctx) = @_;

    local $ENV{GPFORUM_DATABASE_DSN} = $ctx->{dsn};
    return GPForum::Test::PostgresHarness::connect_schema();
}

# $work in a child process, returned from at once so the parent can see it
# wait. The child uses its own connection: the parent's handles are not
# touched, and _exit skips the destructors that would close them.
sub _spawn_worker {
    my ($work) = @_;

    pipe my $out_reader, my $out_writer or croak 'worker pipe failed';
    my $pid = fork;
    if ( !defined $pid ) {
        croak "fork failed: $OS_ERROR";
    }
    if ( $pid == 0 ) {
        close $out_reader or croak 'child worker reader close failed';
        my $payload;
        try {
            my $result = $work->();
            $payload =
              $result ? { ok => 1, result => $result } : { error => q{} };
        }
        catch ($error) {
            $payload = { error => "$error" };
        };
        print {$out_writer} encode_json($payload)
          or croak 'worker result write failed';
        close $out_writer or croak 'child worker writer close failed';
        _exit(0);
    }

    close $out_writer or croak 'parent worker writer close failed';
    return { out => $out_reader, pid => $pid };
}

sub _collect_worker {
    my ($child) = @_;

    local $INPUT_RECORD_SEPARATOR = undef;
    my $json = readline $child->{out};
    close $child->{out} or croak 'parent worker reader close failed';
    waitpid $child->{pid}, 0;

    return decode_json($json);
}

# True once a backend waits on $holder_pid's locks; false if none does
# within BLOCK_POLLS polls.
sub _await_blocked_on {
    my ( $dbh, $holder_pid ) = @_;

    for ( 1 .. $BLOCK_POLLS ) {
        my ($waiting) =
          $dbh->selectrow_array( $BLOCKED_ON_SQL, undef, $holder_pid );
        return 1 if $waiting;
        $dbh->do( 'SELECT pg_sleep(?)', undef, $BLOCK_POLL_SECONDS );
    }

    return 0;
}

sub _downloads_as {
    my ( $ctx, $file, $expected, $where ) = @_;

    for my $who ( sort keys %{$expected} ) {
        is( _download( $ctx->{reader_store}, $file, $ctx->{users}{$who} ),
            $expected->{$who}, "$who: a file on $where is $expected->{$who}" );
    }

    return;
}

# What a download comes to: ok, the refusal, or 'died'.
sub _download {
    my ( $store, $file, $user ) = @_;

    my $download;
    try {
        $download = $store->download_for(
            { attachment_id => $file, viewer_user_id => $user } );
    }
    catch ($error) {
        $download = undef;
    };
    return 'died' if !$download;

    return $download->{ok} ? 'ok' : $download->{error};
}

sub _store {
    my ( $ctx, %options ) = @_;

    return GPForum::Service::Attachment::Store->new(
        clock      => $ctx->{clock},
        id_service => $ctx->{ids},
        schema     => $ctx->{schema},
        %options,
    );
}

# What $method returns from a store whose next lookups in the named
# resultsets lose the race, and whose first ids are the ones given; and how
# many INSERTs it tried. A race the store lost shows as an INSERT PostgreSQL
# refused, which leaves no row to count.
sub _raced {
    my ( $ctx, $race, $method, $input ) = @_;

    my $store = _store(
        $ctx,
        id_service =>
          GPForum::Test::ScriptedId->new( next_ids => $race->{ids} // [] ),
        schema => GPForum::Test::RacedSchema->new(
            misses => $race->{misses} // {},
            schema => $ctx->{schema},
        ),
    );

    return _inserts( $ctx, $TABLE_OF{$method},
        sub { return $store->$method($input); } );
}

# What $code returns, and the INSERT statements into $table it sends, as
# DBIx::Class traces them.
sub _inserts {
    my ( $ctx, $table, $code ) = @_;

    my $storage = $ctx->{schema}->storage;
    my $inserts = 0;
    $storage->debugcb(
        sub {
            my ( undef, $statement ) = @_;
            if ( $statement =~ /\A INSERT [ ] INTO [ ] "?\Q$table\E"? [ ]/msx )
            {
                $inserts++;
            }
            return;
        }
    );
    $storage->debug(1);
    my $result = $code->();
    $storage->debug(0);
    $storage->debugcb(undef);

    return ( $result, $inserts );
}

sub _intent {
    my ( $ctx, $owner, $name ) = @_;

    return GPForum::Service::Attachment::IntentBuilder->new(
        clock      => $ctx->{clock},
        id_service => $ctx->{ids},
    )->build_intent(
        {
            byte_size         => $VALID_BYTES,
            checksum          => $name,
            media_type        => 'image/png',
            original_filename => "$name.png",
            owner_user_id     => $owner,
        }
    );
}

sub _upload {
    my ( $ctx, $media_type ) = @_;

    return {
        actor_user_id     => $ctx->{users}{author},
        content           => $PNG_BYTES,
        media_type        => $media_type,
        original_filename => 'photo.png',
        target_id         => $ctx->{forum}{post},
        target_type       => 'post',
    };
}

sub _event {
    my ( $ctx, $id, $type ) = @_;

    return {
        aggregate_id   => $id,
        aggregate_type => 'attachment',
        event_id       => $ctx->{ids}->uuid,
        event_type     => $type,
    };
}

sub _thumbnail {
    my ( $id, $object_key ) = @_;

    return {
        attachment_id => $id,
        byte_size     => $VARIANT_BYTES,
        media_type    => 'image/webp',
        object_key    => "$object_key/thumb",
        variant_type  => 'thumbnail',
    };
}

# A row written straight to the table -- the files the cases start from.
# Served, by the author, unless the columns say otherwise.
sub _attachment {
    my ( $ctx, $columns ) = @_;

    my $id    = $columns->{attachment_id} // $ctx->{ids}->uuid;
    my $owner = $columns->{owner_user_id} // $ctx->{users}{author};
    my %row   = (
        attachment_id     => $id,
        byte_size         => 1,
        checksum          => 'seeded',
        created_at        => $NOW,
        media_type        => 'text/plain',
        object_key        => "attachments/$owner/$id",
        original_filename => 'seeded.txt',
        owner_user_id     => $owner,
        scan_status       => 'clean',
        state             => 'available',
        %{$columns},
    );
    _insert( $ctx, 'attachments', \%row );

    return $id;
}

sub _intent_row {
    my ( $ctx, $created_at ) = @_;

    return _attachment(
        $ctx,
        {
            created_at  => $created_at,
            scan_status => 'pending',
            state       => 'intent',
        }
    );
}

# An intent whose bytes reached the storage: the upload wrote them, then its
# row, and went no further.
sub _stored_intent {
    my ( $ctx, $storage, $created_at ) = @_;

    my $id = _intent_row( $ctx, $created_at );
    $storage->write_object( _attachment_row( $ctx, $id )->{object_key},
        $PNG_BYTES );

    return $id;
}

sub _storage {
    return GPForum::Service::Attachment::FilesystemStorage->new(
        root => tempdir( CLEANUP => 1 ) );
}

sub _link {
    my ( $ctx, $id, $post ) = @_;

    my $link_id = $ctx->{ids}->uuid;
    _insert(
        $ctx,
        'attachment_links',
        {
            attachment_id      => $id,
            attachment_link_id => $link_id,
            target_id          => $post,
            target_type        => 'post',
        }
    );

    return $link_id;
}

sub _variant {
    my ( $ctx, $id ) = @_;

    my $variant_id = $ctx->{ids}->uuid;
    _insert(
        $ctx,
        'attachment_variants',
        {
            %{ _thumbnail( $id, "variants/$id" ) },
            attachment_variant_id => $variant_id,
        }
    );

    return $variant_id;
}

sub _insert {
    my ( $ctx, $table, $row ) = @_;

    my @columns = sort keys %{$row};
    $ctx->{dbh}->do(
        sprintf(
            'INSERT INTO %s (%s) VALUES (%s)',
            $table, join( q{, }, @columns ),
            join q{, }, (q{?}) x @columns
        ),
        undef,
        @{$row}{@columns}
    );

    return;
}

sub _attachment_row {
    my ( $ctx, $id ) = @_;

    return $ctx->{dbh}->selectrow_hashref( $ATTACHMENT_ROW_SQL, undef, $id )
      // {};
}

sub _events {
    my ( $ctx, $id, $type ) = @_;

    return _count( $ctx, 'event_log',
        { aggregate_id => $id, ( $type ? ( event_type => $type ) : () ) } );
}

sub _audits {
    my ( $ctx, $id, $action ) = @_;

    return _count( $ctx, 'audit_log', { action => $action, target_id => $id } );
}

# Who an attachment's deletion event names, and why.
sub _deletion {
    my ( $ctx, $id ) = @_;

    return [ $ctx->{dbh}->selectrow_array( $DELETION_SQL, undef, $id ) ];
}

sub _count {
    my ( $ctx, $table, $where ) = @_;

    return GPForum::Test::PostgresHarness::count_rows( $ctx->{dbh}, $table,
        $where );
}

sub _utc {
    my ( $ctx, $timestamp ) = @_;

    return _value( $ctx, $UTC_SQL, $timestamp );
}

sub _value {
    my ( $ctx, $sql, @bind ) = @_;

    return scalar $ctx->{dbh}->selectrow_array( $sql, undef, @bind );
}

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

1;
