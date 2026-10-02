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

use GPForum::Infrastructure::Id;
use GPForum::Service::Attachment::Delivery;
use GPForum::Service::Attachment::Event;
use GPForum::Service::Attachment::FilesystemStorage;
use GPForum::Service::Attachment::IntentBuilder;
use GPForum::Service::Attachment::MediaProcessor;
use GPForum::Service::Attachment::Store;
use GPForum::Service::Attachment::UploadPipeline;
use GPForum::Service::Forum::Readability;
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
const my $EARLIER       => '2026-05-23T11:00:00Z';
const my $EARLIEST      => '2026-05-23T10:00:00Z';
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

# The defects this test found in code outside its reach, each pinned where it
# shows (quality program 5.1).
const my $ROW_HASH_TODO =>
  'Attachment::Record::row_hash reads no column of a DBIx::Class row';
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
# a deletion and a post's list of files come back without their columns. And
# t/22 never served a file through a thread, which on PostgreSQL dies.
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

# The purge takes from every intent in the database, so it has one to itself.
my $purge_clone = GPForum::Test::PgDatabase->fresh;
_orphans( _context($purge_clone) );

done_testing();

sub _context {
    my ($database) = @_;

    my $ctx = {
        clock  => GPForum::Test::FixedClock->new,
        dbh    => $database->dbh,
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
            return eval { return $store->create_intent($intent); };
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

    local $TODO = $ROW_HASH_TODO;
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

    local $TODO = $ROW_HASH_TODO;
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
    {
        local $TODO = $ROW_HASH_TODO;
        is( $deleted->{attachment}{attachment_id},
            $id, 'delete_linked reports the attachment it deleted' );
        is( _audits( $ctx, $id, 'attachment.deleted' ),
            1, 'and audits the deletion under its id' );
    }

    my $replay = $store->delete_linked($input);
    ok( $replay->{ok}, 'delete_linked replays an already-deleted row' );
    ok( $replay->{idempotent},
        'delete_linked marks an already-deleted row as idempotent' );
    is( _events( $ctx, $id, 'attachment.deleted' ),
        1, 'a replayed delete records nothing more' );
    {
        local $TODO = $ROW_HASH_TODO;
        is( $replay->{attachment}{attachment_id},
            $id, 'a replayed delete reports the attachment it found deleted' );
    }

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
    {
        local $TODO = $ROW_HASH_TODO;
        is( $replayed->{variant}{variant_type},
            'thumbnail', 'and names the thumbnail it kept' );
    }
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

    local $TODO = $ROW_HASH_TODO;
    is( $listed->{$post}[0]{attachment_id},     $club_file,   'by its id' );
    is( $listed->{$post}[0]{original_filename}, 'seeded.txt', 'and its name' );

    return;
}

# The purge of orphans: intents nobody linked, oldest first and up to the
# limit, soft-deleted with an event in their owner's name, or in the name and
# for the reason the run gives. A linked intent and a served file stay; the
# upload pipeline's purge removes the stored object as well.
sub _orphans {
    my ($ctx) = @_;

    my $oldest = _intent_row( $ctx, $EARLIEST );
    my $orphan = _intent_row( $ctx, $EARLIER );
    my $linked = _intent_row( $ctx, $NOW );
    _link( $ctx, $linked, $ctx->{forum}{post} );
    my $served = _attachment( $ctx, { created_at => $EARLIEST } );
    my $store  = _store($ctx);

    is( scalar @{ $store->cleanup_orphans( { limit => 1 } )->{deleted} },
        1, 'the purge stops at its limit' );
    is( _attachment_row( $ctx, $oldest )->{state},
        'deleted', 'and takes the oldest orphan first' );
    is( _attachment_row( $ctx, $orphan )->{state},
        'intent', 'leaving the next for the following run' );

    my $cleanup = $store->cleanup_orphans( { limit => $PURGE_LIMIT } );
    is( scalar @{ $cleanup->{deleted} }, 1, 'cleanup deletes one orphan' );
    is( _attachment_row( $ctx, $orphan )->{state},
        'deleted', 'cleanup soft-deletes orphan' );
    is( _attachment_row( $ctx, $linked )->{state},
        'intent', 'cleanup keeps linked attachment' );
    is( _attachment_row( $ctx, $served )->{state},
        'available', 'cleanup leaves a served file alone' );
    is_deeply(
        _deletion( $ctx, $orphan ),
        [ $ctx->{users}{author}, 'orphan cleanup' ],
        'the purge records the deletion in the owner\'s name, as orphan cleanup'
    );

    my $swept = _intent_row( $ctx, $EARLIEST );
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

    my $storage = GPForum::Service::Attachment::FilesystemStorage->new(
        root => tempdir( CLEANUP => 1 ) );
    my $crashed = _intent_row( $ctx, $EARLIEST );
    my $key     = _attachment_row( $ctx, $crashed )->{object_key};
    $storage->write_object( $key, $PNG_BYTES );
    GPForum::Service::Attachment::UploadPipeline->new(
        storage => $storage,
        store   => $store,
    )->cleanup_orphans( { limit => $PURGE_LIMIT } );
    is( _attachment_row( $ctx, $crashed )->{state},
        'deleted', 'the upload pipeline purges an orphan too' );

    local $TODO = $ROW_HASH_TODO;
    ok( !$storage->exists_object($key), 'and removes its stored object' );

    return;
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

    my $download = eval {
        return $store->download_for(
            { attachment_id => $file, viewer_user_id => $user } );
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
