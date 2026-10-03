# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Infrastructure::Id;
use GPForum::Schema;
use GPForum::Service::Operations::CommandIdempotency;
use GPForum::Service::Portability::ExportBundleBuilder;
use GPForum::Service::Privacy::DataRightsReview;
use GPForum::Service::Privacy::DeletionWorkflow;
use GPForum::Service::Privacy::RetentionHoldStore;
use GPForum::Service::Privacy::Workflow;
use GPForum::Test::FixedClock;
use GPForum::Test::PgDatabase;
use GPForum::Test::RacedSchema;
use GPForum::Test::ScriptedId;
use GPForum::ViewModel::Privacy::Presenter;

our $VERSION = '0.001';
our $TODO;

const my $NOW   => '2026-05-23T12:00:00Z';
const my $LATER => '2026-05-23T13:00:00Z';
const my $EARLY => '2026-05-23T09:00:00Z';

# When the members signed in: a revocation is never older than its session.
const my $SIGNED_IN => '2026-05-23T08:00:00Z';

const my $REVIEW_LIMIT => 25;
const my $MANY_POSTS   => 7;
const my $BODY_BATCH   => 3;
const my @BATCH_BINDS  => ( 3, 3, 1 );
const my @TRAIL        => ( 1, 1, 1 );
const my $HOLD_ERROR   => 'retention_hold_active';
const my $JOB_ERROR    => 'retention hold active';

# PostgreSQL's lock_not_available: the row is locked by another transaction.
const my $LOCK_NOT_AVAILABLE => '55P03';

# The defects this test found in code outside its reach, each pinned where it
# shows. The manifest one is not cosmetic: the member dashboard template reads
# $request->{manifest}{counts}, which dies under strict refs on the JSON text,
# and the download route sends that text as one JSON string.
const my $BUNDLE_TODO => 'erasure leaves the member\'s stored export bundles';
const my $MANIFEST_TODO =>
  'export manifests are read with get_column, which returns the JSON text';

const my $USER_SQL => join q{ },
  'INSERT INTO users (id, username, display_name, email_normalized,',
  'password_hash, status, trust_level, email_verified_at)',
  q{VALUES (?, ?, 'Forum member', ?, 'hashed', 'active', 1, ?)};
const my $CREDENTIAL_SQL => join q{ },
  'INSERT INTO credentials (id, user_id, type, secret_hash, created_at)',
  q{VALUES (?, ?, 'password', 'hashed', ?)};
const my $SESSION_SQL => join q{ },
  'INSERT INTO sessions (session_id, user_id, session_hash, created_at,',
  q{last_seen_at, expires_at, revoked_at)},
  q{VALUES (?, ?, ?, ?, ?, now() + interval '1 day', ?)};
const my $SPACE_SQL => join q{ },
  'INSERT INTO spaces (space_id, slug, title)',
  q{VALUES (?, 'community', 'Community')};
const my $CATEGORY_SQL => join q{ },
  'INSERT INTO categories (category_id, space_id, slug, title)',
  q{VALUES (?, ?, 'general', 'General')};
const my $THREAD_SQL => join q{ },
  'INSERT INTO threads (thread_id, category_id, author_user_id, title, slug)',
  q{VALUES (?, ?, ?, 'Thread', 'thread')};
const my $POST_SQL => join q{ },
  'INSERT INTO posts (post_id, thread_id, author_user_id, position)',
  'VALUES (?, ?, ?, ?)';
const my $BODY_SQL => join q{ },
  'INSERT INTO post_bodies (body_id, post_id, body_source,',
  q{body_rendered_safe, source_hash) VALUES (?, ?, ?, ?, 'hash')};
const my $ATTACHMENT_SQL => join q{ },
  'INSERT INTO attachments (attachment_id, owner_user_id, object_key,',
  'original_filename, media_type, byte_size, checksum, state, scan_status)',
  q{VALUES (?, ?, 'secret/object', 'notes.txt', 'text/plain', 12, 'abc',},
  q{'available', 'clean')};
const my $INBOX_SQL => join q{ },
  'INSERT INTO notification_inbox (recipient_user_id, notification_id,',
  'created_at) VALUES (?, ?, ?)';
const my $SUBSCRIPTION_SQL => join q{ },
  'INSERT INTO subscriptions (subscription_id, user_id, target_type,',
  q{target_id) VALUES (?, ?, 'thread', ?)};
const my $PREFERENCE_SQL => join q{ },
  'INSERT INTO notification_preferences (user_id, channel)',
  q{VALUES (?, 'email')};
const my $DELETION_REQUEST_SQL => join q{ },
  'INSERT INTO deletion_requests (deletion_request_id, requester_user_id,',
  'resource_type, resource_id, request_type, reason, created_at)',
  q{VALUES (?, ?, 'user', ?, 'anonymize', 'user requested account deletion',},
  '?)';
const my $EXPORT_REQUEST_SQL => join q{ },
  'INSERT INTO export_requests (export_request_id, requester_user_id,',
  q{subject_user_id, export_type, created_at) VALUES (?, ?, ?, 'user_data', ?)};
const my $ERASURE_JOB_SQL => join q{ },
  'INSERT INTO erasure_jobs (erasure_job_id, deletion_request_id,',
  'scheduled_at) VALUES (?, ?, ?)';
const my $HOLD_SQL => join q{ },
  'INSERT INTO retention_holds (retention_hold_id, resource_type,',
  'resource_id, reason, starts_at, ends_at, created_by, created_at)',
  q{VALUES (?, 'user', ?, 'legal investigation', ?, ?, ?, ?)};

# The weakest lock a second approval could take. A FOR SHARE lock held by
# the approval lets it through, and two approvals would then run side by
# side; FOR UPDATE, or FOR NO KEY UPDATE, does not.
const my $LOCK_SQL => join q{ },
  'SELECT deletion_request_id FROM deletion_requests',
  'WHERE deletion_request_id = ? FOR SHARE NOWAIT';

# A timestamp as the clock writes it, whatever zone the server returns it in.
const my $UTC_SQL => join q{ },
  q{SELECT to_char(?::timestamptz AT TIME ZONE 'UTC',},
  q{'YYYY-MM-DD"T"HH24:MI:SS"Z"')};
const my $USER_ROW_SQL => 'SELECT * FROM users WHERE id = ?';
const my $REQUEST_ROW_SQL =>
  'SELECT * FROM deletion_requests WHERE deletion_request_id = ?';
const my $JOB_ROW_SQL => 'SELECT * FROM erasure_jobs WHERE erasure_job_id = ?';
const my $ACTION_ROW_SQL =>
  'SELECT * FROM deletion_actions WHERE deletion_action_id = ?';
const my $HOLD_ROW_SQL =>
  'SELECT * FROM retention_holds WHERE retention_hold_id = ?';
const my $EXPORT_ROW_SQL =>
  'SELECT * FROM export_requests WHERE export_request_id = ?';
const my $CREDENTIAL_ROW_SQL => 'SELECT * FROM credentials WHERE id = ?';
const my $SESSION_ROW_SQL    => 'SELECT * FROM sessions WHERE session_id = ?';
const my $REQUESTS_SQL => join q{ },
  'SELECT count(*) FROM deletion_requests',
  q{WHERE resource_type = 'user' AND resource_id = ?};
const my $ACTIONS_SQL =>
  'SELECT count(*) FROM deletion_actions WHERE deletion_request_id = ?';
const my $ACTION_TYPES_SQL => join q{ },
  'SELECT action_type FROM deletion_actions WHERE deletion_request_id = ?',
  'ORDER BY action_type';
const my $JOBS_SQL =>
  'SELECT count(*) FROM erasure_jobs WHERE deletion_request_id = ?';
const my $HOLDS_SQL => join q{ },
  'SELECT count(*) FROM retention_holds',
  q{WHERE resource_type = 'user' AND resource_id = ?};
const my $EXPORTS_SQL =>
  'SELECT count(*) FROM export_requests WHERE subject_user_id = ?';
const my $COMPLETED_EXPORTS_SQL => join q{ },
  'SELECT count(*) FROM export_requests',
  q{WHERE subject_user_id = ? AND status = 'completed'};
const my $AUTHORED_SQL => join q{ },
  'SELECT b.body_source FROM posts p JOIN post_bodies b USING (post_id)',
  'WHERE p.author_user_id = ? ORDER BY b.body_source';
const my $EVENTS_SQL =>
  'SELECT count(*) FROM event_log WHERE event_type = ? AND aggregate_id = ?';
const my $ALL_EVENTS_SQL =>
  'SELECT count(*) FROM event_log WHERE aggregate_id = ?';
const my $OUTBOX_SQL => join q{ },
  'SELECT count(*) FROM outbox_messages o',
  'JOIN event_log e ON e.event_id = o.event_id',
  'WHERE e.event_type = ? AND e.aggregate_id = ?';
const my $AUDITS_SQL =>
  'SELECT count(*) FROM audit_log WHERE action = ? AND target_id = ?';
const my $ACTIVE_HOLDS_SQL =>
  'SELECT retention_hold_id FROM retention_holds WHERE ends_at IS NULL';

# The erasure's audit entry refused, as a lock or statement timeout would
# refuse it, after every other write of the step.
const my $REFUSE_AUDIT_FUNCTION_SQL => join "\n",
  'CREATE FUNCTION test_refuse_audit() RETURNS trigger',
  'LANGUAGE plpgsql AS $$',
  q{BEGIN RAISE EXCEPTION 'audit write failed'; END},
  q{$$};
const my $REFUSE_AUDIT_TRIGGER_SQL => join q{ },
  'CREATE TRIGGER test_refuse_audit BEFORE INSERT ON audit_log',
  q{FOR EACH ROW WHEN (NEW.action = 'privacy.erasure_completed')},
  'EXECUTE FUNCTION test_refuse_audit()';
const my $ALLOW_AUDIT_SQL => 'DROP TRIGGER test_refuse_audit ON audit_log';

# What the export left behind, read from the database rather than from what
# the store returned.
const my $MANIFEST_EMAIL_SQL => join q{ },
  q{SELECT manifest->'profile'->>'email' FROM export_requests},
  'WHERE export_request_id = ?';
const my $COMPLETED_PAYLOAD_SQL => join q{ },
  q{SELECT payload->'manifest'->'counts'->>'posts',},
  q{payload->'manifest'->'posts' IS NULL,},
  q{payload->'manifest'->'profile' IS NULL FROM event_log},
  q{WHERE event_type = 'privacy.export_completed' AND aggregate_id = ?};
const my $REPLAYED_EMAIL_SQL => join q{ },
  q{SELECT payload->'response'->'stored'->'manifest'->'profile'->>'email'},
  'FROM command_log WHERE idempotency_key = ?';

# The transaction that last wrote a row: a row that keeps it was not
# written since, not even with the values it already held.
const my %VERSION_SQL => (
    job     => 'SELECT xmin::text FROM erasure_jobs WHERE erasure_job_id = ?',
    request =>
      'SELECT xmin::text FROM deletion_requests WHERE deletion_request_id = ?',
);

if ( !GPForum::Test::PgDatabase->admin_dsn ) {
    plan skip_all => 'set GPFORUM_TEST_DSN to run against PostgreSQL';
}

# A member's data rights on PostgreSQL: the export bundle, the deletion
# request, its approval, the legal holds that stop it and the erasure job
# that anonymizes the member, and the export command's replay. These ran in
# t/29 and t/101 on a fake ORM that counted the rows a store created,
# compared timestamps as the clock's strings, kept a manifest as the hash it
# was given and made a race a lookup told to miss. Here a rival connection
# commits the competing row between a store's lookup and its insert,
# PostgreSQL raises the conflict the store recovers from, the manifest comes
# back as PostgreSQL stores it, and what is erased and what is kept is read
# back from the tables.
#
# The story -- one member's export and erasure, the holds that block two
# others, and the review screens over all of it -- runs in its own database,
# so the review's lists hold exactly what the story wrote. The export
# requests, the races, the id collisions, a hold that ends, an erasure
# that rolls back and the workflow's answers run in a second.
my $story_database = GPForum::Test::PgDatabase->fresh;
my $story          = _context($story_database);

_export_bundle($story);
_deletion_request($story);
_approval($story);
_approval_replays($story);
_erasure($story);
_erasure_replays($story);
_retention_holds($story);
_hold_blocks_approval($story);
_hold_blocks_erasure($story);
_hold_block_replays($story);
_review($story);
_export_review($story);

$story->{rival}->storage->disconnect;

my $race_database = GPForum::Test::PgDatabase->fresh;
my $races         = _context($race_database);

_export_requests($races);
_export_request_race($races);
_export_id_collision($races);
_export_id_race($races);
_export_many_posts($races);
_commanded_export($races);
_deletion_request_race($races);
_deletion_id_collision($races);
_deletion_id_race($races);
_erasure_id_collision($races);
_erasure_id_race($races);
_action_id_collision($races);
_hold_race($races);
_hold_id_collision($races);
_hold_id_race($races);
_hold_ends($races);
_erasure_rolls_back($races);
_workflow_outcomes($races);

$races->{rival}->storage->disconnect;

done_testing();

sub _context {
    my ($database) = @_;

    my $ctx = {
        clock  => GPForum::Test::FixedClock->new,
        dbh    => $database->dbh,
        ids    => GPForum::Infrastructure::Id->new,
        rival  => _rival_schema($database),
        schema => $database->schema,
        serial => 0,
        users  => {},
    };
    _forum($ctx);

    return $ctx;
}

# A second connection to the same database: the concurrent request.
sub _rival_schema {
    my ($database) = @_;

    local $ENV{GPFORUM_DATABASE_DSN} = $database->dsn;

    return GPForum::Schema->connect_from_config(
        GPForum::Config->from_environment );
}

sub _member {
    my ( $ctx, $name ) = @_;

    my $id = $ctx->{ids}->uuid;
    $ctx->{dbh}
      ->do( $USER_SQL, undef, $id, $name, "$name\@example.test", $NOW );
    $ctx->{users}{$name} = $id;

    return $id;
}

sub _credential {
    my ( $ctx, $user ) = @_;

    my $id = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $CREDENTIAL_SQL, undef, $id, $user, $SIGNED_IN );

    return $id;
}

sub _session {
    my ( $ctx, $user, $revoked_at ) = @_;

    my $id = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $SESSION_SQL, undef, $id, $user, $id, $SIGNED_IN,
        $SIGNED_IN, $revoked_at );

    return $id;
}

# One thread to write in.
sub _forum {
    my ($ctx) = @_;

    my $space    = $ctx->{ids}->uuid;
    my $category = $ctx->{ids}->uuid;
    $ctx->{thread} = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $SPACE_SQL, undef, $space );
    $ctx->{dbh}->do( $CATEGORY_SQL, undef, $category, $space );
    $ctx->{dbh}->do( $THREAD_SQL, undef, $ctx->{thread}, $category,
        _member( $ctx, 'host' ) );

    return;
}

sub _post {
    my ( $ctx, $author, $body ) = @_;

    my $id = $ctx->{ids}->uuid;
    $ctx->{dbh}
      ->do( $POST_SQL, undef, $id, $ctx->{thread}, $author, ++$ctx->{serial} );
    $ctx->{dbh}
      ->do( $BODY_SQL, undef, $ctx->{ids}->uuid, $id, $body, "<p>$body</p>" );

    return $id;
}

sub _deletion {
    my ( $ctx, %options ) = @_;

    return GPForum::Service::Privacy::DeletionWorkflow->new(
        clock      => $ctx->{clock},
        id_service => $ctx->{ids},
        schema     => $ctx->{schema},
        %options,
    );
}

sub _holds {
    my ( $ctx, %options ) = @_;

    return GPForum::Service::Privacy::RetentionHoldStore->new(
        clock      => $ctx->{clock},
        id_service => $ctx->{ids},
        schema     => $ctx->{schema},
        %options,
    );
}

sub _exports {
    my ( $ctx, %options ) = @_;

    return GPForum::Service::Portability::ExportBundleBuilder->new(
        clock      => $ctx->{clock},
        id_service => $ctx->{ids},
        schema     => $ctx->{schema},
        %options,
    );
}

sub _reviewer {
    my ($ctx) = @_;

    return GPForum::Service::Privacy::DataRightsReview->new(
        schema => $ctx->{schema} );
}

# The workflow the privacy routes call, over the real stores, with the
# command log that replays an export.
sub _workflow {
    my ($ctx) = @_;

    return GPForum::Service::Privacy::Workflow->new(
        command_idempotency =>
          GPForum::Service::Operations::CommandIdempotency->new(
            clock      => $ctx->{clock},
            id_service => $ctx->{ids},
            schema     => $ctx->{schema},
          ),
        deletion_workflow => _deletion($ctx),
        export_builder    => _exports($ctx),
        hold_store        => _holds($ctx),
        reviewer          => _reviewer($ctx),
    );
}

# A member asking to be erased: about themselves unless another subject is
# named.
sub _erase_request {
    my ( $requester, $subject, $reason ) = @_;

    return {
        reason            => $reason // 'user requested account deletion',
        request_type      => 'anonymize',
        requester_user_id => $requester,
        resource_id       => $subject // $requester,
        resource_type     => 'user',
    };
}

sub _hold_input {
    my ( $subject, $staff, $reason ) = @_;

    return {
        created_by    => $staff,
        reason        => $reason // 'legal investigation',
        resource_id   => $subject,
        resource_type => 'user',
    };
}

# A member's export through the workflow, as the route runs it: the request,
# the bundle read from every table the member has rows in, the completion --
# and what never leaves with it.
sub _export_bundle {
    my ($ctx) = @_;

    my $member = _member( $ctx, 'subject' );
    $ctx->{dbh}->do( q{UPDATE users SET preferred_locale = 'it' WHERE id = ?},
        undef, $member );
    my @posts =
      map { _post( $ctx, $member, $_ ) } ( 'Hello from export', 'Second post' );
    _post( $ctx, _member( $ctx, 'bystander' ), 'Not part of the export' );
    my $notification = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $ATTACHMENT_SQL, undef, $ctx->{ids}->uuid, $member );
    $ctx->{dbh}->do( $INBOX_SQL, undef, $member, $notification, $NOW );
    $ctx->{dbh}->do(
        $SUBSCRIPTION_SQL, undef, $ctx->{ids}->uuid,
        $member,           $ctx->{thread}
    );
    $ctx->{dbh}->do( $PREFERENCE_SQL, undef, $member );

    my $exported =
      _workflow($ctx)
      ->request_export(
        { command_id => 'export-subject-1', user_id => $member } );
    ok( $exported->{ok}, 'request_export succeeds for a known member' );
    my $stored = $exported->{stored};
    my $id     = $stored->{export_request_id};
    ok(
        GPForum::Infrastructure::Id->is_uuid($id),
        'export request id is generated'
    );
    is( $stored->{status}, 'completed',
        'request_export returns the completed export' );
    is( $stored->{format}, 'json', 'export defaults to json' );
    my $row = _row( $ctx, $EXPORT_ROW_SQL, $id );
    is( $row->{status}, 'completed', 'export completion persists status' );
    is( _utc( $ctx, $row->{finished_at} ), $NOW, 'and the time it finished' );

    my $manifest = $stored->{manifest};
    is_deeply(
        $manifest->{counts},
        {
            attachments   => 1,
            notifications => 1,
            posts         => 2,
            preferences   => 1,
            subscriptions => 1,
        },
        'the manifest counts each part of the bundle'
    );
    is( $manifest->{profile}{email},
        'subject@example.test', 'the export includes the member email' );
    is( $manifest->{profile}{username},
        'subject', 'the export includes the public profile' );
    is( $manifest->{profile}{preferred_locale},
        'it', 'the export includes the member preferences' );
    ok(
        !exists $manifest->{profile}{password_hash},
        'the export omits the password hash'
    );
    is_deeply(
        [ sort map { $_->{body_source} } @{ $manifest->{posts} } ],
        [ 'Hello from export', 'Second post' ],
        'the export includes each post the member wrote, with its source'
    );
    is_deeply(
        [ sort map { $_->{post_id} } @{ $manifest->{posts} } ],
        [ sort @posts ],
        'and no post another member wrote'
    );
    ok(
        !grep( { exists $_->{index} } @{ $manifest->{posts} } ),
        'the export does not use placeholder index rows'
    );
    is( $manifest->{attachments}[0]{original_filename},
        'notes.txt', 'the export includes attachment names' );
    ok(
        !exists $manifest->{attachments}[0]{object_key},
        'the export omits storage object keys'
    );
    is( $manifest->{notifications}[0]{notification_id},
        $notification, 'the export includes inbox rows' );
    is( $manifest->{subscriptions}[0]{target_id},
        $ctx->{thread}, 'the export includes subscriptions' );
    is( $manifest->{preferences}[0]{channel},
        'email', 'the export includes notification preferences' );
    is( _value( $ctx, $MANIFEST_EMAIL_SQL, $id ),
        'subject@example.test',
        'the bundle is stored as the request manifest' );

    _export_trail( $ctx, $member );
    _export_completed_again( $ctx, $id );
    $ctx->{export} = $id;

    return;
}

sub _export_trail {
    my ( $ctx, $member ) = @_;

    is_deeply( _trail( $ctx, 'privacy.export_requested', $member ),
        [@TRAIL], 'the export request records its event, outbox and audit' );
    is_deeply( _trail( $ctx, 'privacy.export_completed', $member ),
        [@TRAIL], 'export completion records its own' );
    is_deeply(
        [
            $ctx->{dbh}
              ->selectrow_array( $COMPLETED_PAYLOAD_SQL, undef, $member )
        ],
        [ 2, 1, 1 ],
'export completion event keeps counts, and omits post bodies and profile'
    );

    return;
}

sub _export_completed_again {
    my ( $ctx, $id ) = @_;

    my $again = _exports($ctx)
      ->complete_user_export( $id, { profile => { username => 'changed' } } );
    is( $again->{status}, 'completed', 'export completion is idempotent' );
    is( _manifest( $again->{manifest} )->{profile}{username},
        'subject', 'and returns the bundle as stored, not the parts passed' );
  TODO: {
        local $TODO = $MANIFEST_TODO;
        is( ref $again->{manifest},
            'HASH',
            'an already completed export returns its manifest decoded' );
    }
    is(
        _value(
            $ctx,                       $AUDITS_SQL,
            'privacy.export_completed', $again->{subject_user_id}
        ),
        1,
        'idempotent export completion avoids duplicate audit rows'
    );
    is( _exports($ctx)->complete_user_export( $ctx->{ids}->uuid ),
        undef, 'an unknown export request completes nothing' );

    return;
}

sub _deletion_request {
    my ($ctx) = @_;

    my $subject = $ctx->{users}{subject};
    $ctx->{credential}     = _credential( $ctx, $subject );
    $ctx->{session}        = _session( $ctx, $subject );
    $ctx->{revoked}        = _session( $ctx, $subject, $EARLY );
    $ctx->{other_session}  = _session( $ctx, $ctx->{users}{bystander} );
    $ctx->{other_password} = _credential( $ctx, $ctx->{users}{bystander} );

    my $workflow = _deletion($ctx);
    my $request  = $workflow->request_deletion( _erase_request($subject) );
    my $id       = $request->{deletion_request_id};
    ok(
        GPForum::Infrastructure::Id->is_uuid($id),
        'deletion request id is generated'
    );
    is( $request->{requester_user_id},
        $subject, 'deletion request stores requester' );
    is( $request->{resource_type},
        'user', 'deletion request stores resource type' );
    is( $request->{resource_id},
        $subject, 'deletion request stores resource id' );
    is( $request->{request_type},
        'anonymize', 'deletion request stores request type' );
    is( $request->{status},     'pending', 'deletion request starts pending' );
    is( $request->{created_at}, $NOW, 'deletion request stores timestamp' );
    is( _value( $ctx, $REQUESTS_SQL, $subject ),
        1, 'deletion request row is inserted' );
    is( _row( $ctx, $REQUEST_ROW_SQL, $id )->{status},
        'pending', 'and stored pending' );
    is_deeply( _trail( $ctx, 'privacy.deletion_requested', $subject ),
        [@TRAIL], 'deletion request records its event, outbox and audit' );

    my $again = $workflow->request_deletion(
        _erase_request(
            $subject, undef, 'user requested account deletion again'
        )
    );
    is( $again->{deletion_request_id},
        $id, 'retry reuses the open deletion request' );
    is( _value( $ctx, $REQUESTS_SQL, $subject ),
        1, 'retry does not insert a second deletion request' );
    is( _value( $ctx, $EVENTS_SQL, 'privacy.deletion_requested', $subject ),
        1, 'retry does not emit a second deletion event' );
    $ctx->{request} = $id;

    return;
}

# The approval locks the request before it reads it: while it runs, another
# transaction cannot lock the row, not even to share it, so two approvals
# cannot both schedule a job (t/integration/postgres-concurrency.t races
# two; its unique index keeps one job whatever the lock).
sub _approval {
    my ($ctx) = @_;

    my $id    = $ctx->{request};
    my $staff = _member( $ctx, 'admin' );
    my $locked;
    my ( $approved, $sent ) = _statements(
        $ctx,
        sub {
            my ($statement) = @_;
            if ( !defined $locked
                && $statement =~
                /\A SELECT [ ] .* [ ] FROM [ ] deletion_requests [ ]/msx )
            {
                $locked = _lock_state( $ctx, $id );
            }
            return;
        },
        sub {
            return _deletion($ctx)
              ->approve_request( $id, $staff,
                'verified account owner request' );
        }
    );
    is( $locked, $LOCK_NOT_AVAILABLE,
            'approval locks the deletion request row, against another approval,'
          . ' before reading it' );
    is( $approved->{request_id}, $id, 'approval returns request id' );
    my $action = $approved->{action};
    ok( GPForum::Infrastructure::Id->is_uuid( $action->{deletion_action_id} ),
        'approval action id is generated' );
    is( $action->{actor_id},    $staff,     'approval action stores actor' );
    is( $action->{action_type}, 'released', 'approval records release action' );
    ok(
        GPForum::Infrastructure::Id->is_uuid(
            $approved->{job}{erasure_job_id}
        ),
        'erasure job id is generated'
    );
    is( $approved->{job}{status}, 'pending', 'erasure job starts pending' );
    is( _row( $ctx, $REQUEST_ROW_SQL, $id )->{status},
        'approved', 'deletion request row is approved' );
    is( _value( $ctx, $ACTIONS_SQL, $id ), 1, 'approval action is inserted' );
    is( _value( $ctx, $JOBS_SQL,    $id ), 1, 'erasure job is inserted' );
    is_deeply(
        _trail( $ctx, 'privacy.deletion_approved', $ctx->{users}{subject} ),
        [@TRAIL], 'approval records its event, outbox and audit' );
    my %scheduling = map { $_ => 1 } qw(erasure_jobs deletion_actions);
    is_deeply(
        [ grep { $scheduling{$_} } _inserted_tables($sent) ],
        [qw(erasure_jobs deletion_actions)],
        'and schedules the job before it records the release'
    );
    $ctx->{staff} = $staff;
    $ctx->{job}   = $approved->{job}{erasure_job_id};

    return;
}

sub _approval_replays {
    my ($ctx) = @_;

    my ( $id, $staff, $job ) = @{$ctx}{qw(request staff job)};
    my $again =
      _deletion($ctx)
      ->approve_request( $id, $staff, 'retry after network timeout' );
    ok( $again->{idempotent}, 'repeated approval reuses existing job' );
    is( $again->{job}{erasure_job_id},
        $job, 'repeated approval returns the original erasure job' );
    is( _value( $ctx, $JOBS_SQL, $id ),
        1, 'repeated approval avoids duplicate erasure jobs' );
    is( _value( $ctx, $ACTIONS_SQL, $id ),
        1, 'repeated approval avoids duplicate deletion actions' );

    # Under the approval's lock no concurrent writer can commit the job
    # between the lookup and the insert, so the lookup is scripted to miss;
    # the insert, the unique violation and the recovery are PostgreSQL's.
    my $raced = GPForum::Test::RacedSchema->new(
        misses => { ErasureJob => 1 },
        schema => $ctx->{schema},
    );
    my ( $replayed, $sent ) = _statements(
        $ctx, undef,
        sub {
            return _deletion( $ctx, schema => $raced )
              ->approve_request( $id, $staff,
                'concurrent approval after lookup miss' );
        }
    );
    is( _inserts( $sent, 'erasure_jobs' ),
        1, 'the raced approval tries to insert a second job' );
    ok( $replayed->{idempotent},
        'unique race reuses the existing erasure job' );
    is( $replayed->{job}{erasure_job_id},
        $job, 'unique race returns the original erasure job' );
    is( _value( $ctx, $JOBS_SQL, $id ),
        1, 'unique race does not insert a second erasure job' );
    is( _value( $ctx, $ACTIONS_SQL, $id ),
        1, 'unique race does not insert a second approval action' );

    return;
}

sub _erasure {
    my ($ctx) = @_;

    my ( $subject, $id, $job ) =
      ( $ctx->{users}{subject}, @{$ctx}{qw(request job)} );
    my $worker    = _member( $ctx, 'worker' );
    my $completed = _deletion($ctx)->complete_job( $job, $worker );
    is( $completed->{erasure_job_id}, $job, 'completion returns job id' );
    ok(
        GPForum::Infrastructure::Id->is_uuid(
            $completed->{action}{deletion_action_id}
        ),
        'completion action id is generated'
    );
    is( $completed->{action}{action_type},
        'anonymized', 'completion records anonymization action' );
    is_deeply(
        $completed->{anonymized},
        { idempotent => 0, user_id => $subject },
        'completion names the member it anonymized'
    );
    my $job_row = _row( $ctx, $JOB_ROW_SQL, $job );
    is( $job_row->{status}, 'done', 'erasure job row is completed' );
    is( _utc( $ctx, $job_row->{completed_at} ),
        $NOW, 'and stamped with the time it ran' );
    my $request_row = _row( $ctx, $REQUEST_ROW_SQL, $id );
    is( $request_row->{status},
        'completed', 'deletion request row is completed' );
    is( _utc( $ctx, $request_row->{completed_at} ),
        $NOW, 'and stamped with the same time' );
    is_deeply(
        [
            map { $_->[0] } @{
                $ctx->{dbh}->selectall_arrayref( $ACTION_TYPES_SQL, undef, $id )
            }
        ],
        [qw(anonymized released)],
        'completion action is inserted'
    );
    $ctx->{worker} = $worker;

    _erased_identity($ctx);
    _erasure_keeps($ctx);

    return;
}

# What the erasure takes away: the member's identity, their way in, and
# nothing of anyone else's.
sub _erased_identity {
    my ($ctx) = @_;

    my $subject = $ctx->{users}{subject};
    ( my $token = lc $subject ) =~ s/[^[:alnum:]]//gmsx;
    my $user = _row( $ctx, $USER_ROW_SQL, $subject );
    is(
        $user->{display_name},
        'Deleted member',
        'erasure anonymizes public display name'
    );
    is(
        $user->{email_normalized},
        "deleted+$token\@example.invalid",
        'erasure replaces private email with invalid tombstone'
    );
    is_deeply(
        [
            @{$user}
              {qw(username password_hash status trust_level email_verified_at)}
        ],
        [ "deleted-$token", 'erased', 'deleted', 0, undef ],
        'erasure replaces username and password, and drops status, trust and'
          . ' verification'
    );
    is( _utc( $ctx, $user->{deleted_at} ),
        $NOW, 'erasure marks the member deleted' );
    is( _utc( $ctx, $user->{updated_at} ),
        $NOW, 'and stamps the member row with the time it ran' );
    is(
        _utc(
            $ctx,
            _row( $ctx, $CREDENTIAL_ROW_SQL, $ctx->{credential} )->{revoked_at}
        ),
        $NOW,
        'erasure revokes credentials'
    );
    is(
        _utc(
            $ctx, _row( $ctx, $SESSION_ROW_SQL, $ctx->{session} )->{revoked_at}
        ),
        $NOW,
        'erasure revokes sessions'
    );
    is(
        _utc(
            $ctx, _row( $ctx, $SESSION_ROW_SQL, $ctx->{revoked} )->{revoked_at}
        ),
        $EARLY,
        'a session revoked before keeps its revocation time'
    );
    is_deeply(
        [
            _row( $ctx, $SESSION_ROW_SQL, $ctx->{other_session} )->{revoked_at},
            _row( $ctx, $CREDENTIAL_ROW_SQL, $ctx->{other_password} )
              ->{revoked_at},
        ],
        [ undef, undef ],
        'another member keeps their session and credential'
    );

    return;
}

# What the erasure keeps: the member's row under its id, what they wrote, so
# the conversation still reads, and the record of the erasure itself. Not
# the copy of their data the export stored.
sub _erasure_keeps {
    my ($ctx) = @_;

    my $subject = $ctx->{users}{subject};
    is( _row( $ctx, $USER_ROW_SQL, $subject )->{id},
        $subject, 'the member row is kept under its id' );
    is_deeply(
        [
            map { $_->[0] } @{
                $ctx->{dbh}
                  ->selectall_arrayref( $AUTHORED_SQL, undef, $subject )
            }
        ],
        [ 'Hello from export', 'Second post' ],
        'the member posts are kept with their bodies'
    );
    is_deeply(
        [
            map { _value( $ctx, $AUDITS_SQL, $_, $subject ) }
              qw(privacy.deletion_requested privacy.deletion_approved
              privacy.erasure_completed)
        ],
        [@TRAIL],
        'the audit trail keeps the request, the approval and the erasure'
    );
    is_deeply( _trail( $ctx, 'privacy.erasure_completed', $subject ),
        [@TRAIL], 'erasure records its event, outbox and audit' );

  TODO: {
        local $TODO = $BUNDLE_TODO;
        is( _value( $ctx, $MANIFEST_EMAIL_SQL, $ctx->{export} ),
            undef, 'erasure clears the email from the stored export bundle' );
        is( _value( $ctx, $REPLAYED_EMAIL_SQL, 'export-subject-1' ),
            undef, 'and from the export response the command log replays' );
    }

    return;
}

sub _erasure_replays {
    my ($ctx) = @_;

    my ( $id, $job, $worker ) = @{$ctx}{qw(request job worker)};
    my $version = _version( $ctx, request => $id );
    my $again   = _deletion($ctx)->complete_job( $job, $worker );
    ok( $again->{idempotent}, 'completed erasure job is idempotent' );
    is( _value( $ctx, $ACTIONS_SQL, $id ),
        2, 'idempotent completion avoids duplicate actions' );
    is( _version( $ctx, request => $id ),
        $version, 'already-completed deletion request is not restamped' );
    is( _utc( $ctx, _row( $ctx, $REQUEST_ROW_SQL, $id )->{completed_at} ),
        $NOW,
        'already-completed deletion request keeps the original timestamp' );

    # A request the job finished but that was left open: an hour on, so a
    # completion stamped from the clock rather than from the job would show.
    $ctx->{dbh}->do(
        q{UPDATE deletion_requests SET status = 'approved', completed_at = NULL}
          . ' WHERE deletion_request_id = ?',
        undef, $id
    );
    $ctx->{clock}->iso8601($LATER);
    my $incomplete = _deletion($ctx)->complete_job( $job, $worker );
    $ctx->{clock}->iso8601($NOW);
    ok( $incomplete->{idempotent},
        'incomplete request completion retry stays idempotent' );
    my $row = _row( $ctx, $REQUEST_ROW_SQL, $id );
    is( $row->{status}, 'completed',
        'incomplete request completion retry restores completed status' );
    is(
        _utc( $ctx, $row->{completed_at} ),
        $NOW,
        'incomplete request completion retry uses the job completed timestamp'
    );
    is( _value( $ctx, $ACTIONS_SQL, $id ),
        2,
        'incomplete request completion retry avoids a second complete action' );

    return;
}

sub _retention_holds {
    my ($ctx) = @_;

    my $held  = _member( $ctx, 'held' );
    my $staff = _member( $ctx, 'legal' );
    my $hold  = _holds($ctx)->create_hold( _hold_input( $held, $staff ) );
    ok( GPForum::Infrastructure::Id->is_uuid( $hold->{retention_hold_id} ),
        'retention hold id is generated' );
    is( $hold->{resource_type}, 'user', 'retention hold stores resource type' );
    is( $hold->{reason}, 'legal investigation',
        'retention hold stores reason' );
    is( $hold->{created_by}, $staff, 'retention hold stores creator' );
    is( _value( $ctx, $HOLDS_SQL, $held ), 1,
        'retention hold row is inserted' );
    is( _row( $ctx, $HOLD_ROW_SQL, $hold->{retention_hold_id} )->{ends_at},
        undef, 'and stays active until it is ended' );
    is_deeply( _trail( $ctx, 'privacy.retention_hold_created', $held ),
        [@TRAIL], 'retention hold records its event, outbox and audit' );

    my $again =
      _holds($ctx)
      ->create_hold(
        _hold_input( $held, $staff, 'legal investigation retry' ) );
    is(
        $again->{retention_hold_id},
        $hold->{retention_hold_id},
        'retry reuses the active retention hold'
    );
    is( _value( $ctx, $HOLDS_SQL, $held ),
        1, 'retry does not insert a second retention hold' );
    $ctx->{legal} = $staff;
    $ctx->{hold}  = $hold->{retention_hold_id};

    return;
}

sub _hold_blocks_approval {
    my ($ctx) = @_;

    my $held      = $ctx->{users}{held};
    my $requester = _member( $ctx, 'requester' );
    my $workflow  = _deletion($ctx);
    my $request   = $workflow->request_deletion(
        _erase_request( $requester, $held, 'delete held account' ) );
    my $id = $request->{deletion_request_id};
    my $blocked =
      $workflow->approve_request( $id, $ctx->{staff}, 'legal hold active' );
    ok( !$blocked->{ok}, 'active legal hold blocks deletion approval' );
    is( $blocked->{error}, $HOLD_ERROR, 'blocked approval reports hold error' );
    is( _row( $ctx, $REQUEST_ROW_SQL, $id )->{status},
        'held', 'blocked approval marks request held' );
    is( _value( $ctx, $JOBS_SQL, $id ),
        0, 'blocked approval does not create an erasure job' );
    my $action =
      _row( $ctx, $ACTION_ROW_SQL, $blocked->{action}{deletion_action_id} );
    is( $action->{action_type},
        'held', 'blocked approval records a held action' );
    is(
        _value(
            $ctx,
            q{SELECT metadata->>'retention_hold_id' FROM deletion_actions}
              . ' WHERE deletion_action_id = ?',
            $action->{deletion_action_id}
        ),
        $ctx->{hold},
        'naming the hold that stopped it'
    );
    is_deeply( _trail( $ctx, 'privacy.deletion_held', $held ),
        [@TRAIL], 'blocked approval records its event, outbox and audit' );

    # Asked again while the hold stands, the approval finds the request held
    # already and writes nothing.
    my $version = _version( $ctx, request => $id );
    my $again =
      $workflow->approve_request( $id, $ctx->{staff}, 'legal hold active' );
    is_deeply(
        [ @{$again}{qw(ok error action)} ],
        [ 0, $HOLD_ERROR, undef ],
        'a held request approved again stays held, with no new action'
    );
    is( _value( $ctx, $ACTIONS_SQL, $id ),
        1, 'blocked approval retry avoids a second held action' );
    is_deeply( _trail( $ctx, 'privacy.deletion_held', $held ),
        [@TRAIL], 'blocked approval retry avoids a second hold event' );
    is( _version( $ctx, request => $id ),
        $version, 'and leaves the held request as it was' );
    $ctx->{requester}       = $requester;
    $ctx->{blocked_request} = $id;

    return;
}

sub _hold_blocks_erasure {
    my ($ctx) = @_;

    my $subject    = _member( $ctx, 'evidence' );
    my $credential = _credential( $ctx, $subject );
    my $workflow   = _deletion($ctx);
    my $request    = $workflow->request_deletion(
        _erase_request(
            _member( $ctx, 'reviewer' ),
            $subject,
            'delete account after review'
        )
    );
    my $id       = $request->{deletion_request_id};
    my $approval = $workflow->approve_request( $id, $ctx->{staff},
        'approved before later hold' );
    ok( $approval->{ok}, 'an approval before the hold schedules the job' );
    my $job = $approval->{job}{erasure_job_id};
    my $hold =
      _holds($ctx)
      ->create_hold(
        _hold_input( $subject, $ctx->{legal}, 'preserve evidence' ) );

    my $blocked = $workflow->complete_job( $job, $ctx->{worker} );
    ok( !$blocked->{ok}, 'active legal hold blocks erasure job' );
    is( $blocked->{error}, $HOLD_ERROR, 'blocked erasure reports hold error' );
    my $job_row = _row( $ctx, $JOB_ROW_SQL, $job );
    is( $job_row->{last_error},
        $JOB_ERROR, 'blocked erasure stores retryable job error' );
    is( $job_row->{status}, 'pending', 'and leaves the job to run again' );
    is( _row( $ctx, $REQUEST_ROW_SQL, $id )->{status},
        'held', 'blocked erasure marks request held' );
    is( $hold->{resource_id}, $subject,
        'second legal hold targets later erasure subject' );
    is_deeply(
        [
            @{ _row( $ctx, $USER_ROW_SQL, $subject ) }
              {qw(display_name email_normalized status deleted_at)},
            _row( $ctx, $CREDENTIAL_ROW_SQL, $credential )->{revoked_at},
        ],
        [ 'Forum member', 'evidence@example.test', 'active', undef, undef ],
        'the held member is not erased'
    );
    is_deeply( _trail( $ctx, 'privacy.erasure_blocked', $subject ),
        [@TRAIL], 'blocked erasure records its event, outbox and audit' );
    $ctx->{evidence}     = $subject;
    $ctx->{held_request} = $id;
    $ctx->{held_job}     = $job;
    $ctx->{job_hold}     = $hold->{retention_hold_id};

    return;
}

sub _hold_block_replays {
    my ($ctx) = @_;

    my ( $subject, $id, $job ) = @{$ctx}{qw(evidence held_request held_job)};
    my $actions = _value( $ctx, $ACTIONS_SQL,    $id );
    my $events  = _value( $ctx, $ALL_EVENTS_SQL, $subject );
    my $again   = _deletion($ctx)->complete_job( $job, $ctx->{worker} );
    ok( $again->{idempotent}, 'blocked erasure job retry is idempotent' );
    ok( !$again->{ok},        'blocked erasure job retry stays blocked' );
    is( $again->{error}, $HOLD_ERROR,
        'blocked erasure job retry reports hold error' );
    is( _value( $ctx, $ACTIONS_SQL, $id ),
        $actions, 'blocked erasure job retry avoids duplicate actions' );
    is( _value( $ctx, $ALL_EVENTS_SQL, $subject ),
        $events, 'blocked erasure job retry avoids duplicate events' );

    my $request_version = _version( $ctx, request => $id );
    $ctx->{dbh}->do(
        'UPDATE erasure_jobs SET last_error = NULL WHERE erasure_job_id = ?',
        undef, $job );
    my $lost_error = _deletion($ctx)->complete_job( $job, $ctx->{worker} );
    ok( !$lost_error->{ok}, 'incomplete last_error retry stays blocked' );
    is( _row( $ctx, $JOB_ROW_SQL, $job )->{last_error},
        $JOB_ERROR, 'incomplete last_error retry restores the job error' );
    is( _version( $ctx, request => $id ),
        $request_version, 'already-held deletion request is not restamped' );
    is( _value( $ctx, $ACTIONS_SQL, $id ),
        $actions, 'incomplete last_error retry avoids a second hold action' );
    is( _value( $ctx, $ALL_EVENTS_SQL, $subject ),
        $events, 'incomplete last_error retry avoids a second hold event' );

    $ctx->{dbh}->do(
        q{UPDATE deletion_requests SET status = 'approved'}
          . ' WHERE deletion_request_id = ?',
        undef, $id
    );
    my $job_version = _version( $ctx, job => $job );
    my $lost_status = _deletion($ctx)->complete_job( $job, $ctx->{worker} );
    ok( !$lost_status->{ok}, 'incomplete held-status retry stays blocked' );
    is( _row( $ctx, $REQUEST_ROW_SQL, $id )->{status},
        'held', 'incomplete held-status retry restores held' );
    is( _version( $ctx, job => $job ),
        $job_version, 'already-blocked job error is not restamped' );
    is( _value( $ctx, $ACTIONS_SQL, $id ),
        $actions, 'incomplete held-status retry avoids a second hold action' );
    is( _value( $ctx, $ALL_EVENTS_SQL, $subject ),
        $events, 'incomplete held-status retry avoids a second hold event' );

    return;
}

# The review screens over what the story wrote: one completed request, two
# held ones, two active holds, one done job and one blocked.
sub _review {
    my ($ctx) = @_;

    my ( $active, $sent ) = _statements(
        $ctx, undef,
        sub {
            return _holds($ctx)
              ->active_holds_for( 'user', $ctx->{users}{held}, $REVIEW_LIMIT );
        }
    );
    is( scalar @{$active}, 1, 'active holds can be listed' );

    # One active hold per resource is all the schema allows, so the limit
    # cannot show in the rows: it shows in the statement, bound last.
    my $holds_read = qr/\A SELECT [ ] .* [ ] FROM [ ] retention_holds [ ]/msx;
    my $limit_last = qr/[ ] LIMIT [ ] [?] : [ ] .* '$REVIEW_LIMIT' \s* \z/msx;
    ok( scalar( grep { /$holds_read/msx && /$limit_last/msx } @{$sent} ),
        'active holds apply limit' );

    _review_requests($ctx);
    _review_holds($ctx);
    _review_jobs($ctx);

    return;
}

sub _review_requests {
    my ($ctx) = @_;

    my $review = _reviewer($ctx);
    $ctx->{clock}->iso8601($EARLY);
    my $oldest =
      _deletion($ctx)
      ->request_deletion( _erase_request( _member( $ctx, 'early' ) ) )
      ->{deletion_request_id};
    $ctx->{clock}->iso8601($NOW);
    my $newer =
      _deletion($ctx)
      ->request_deletion( _erase_request( _member( $ctx, 'late' ) ) )
      ->{deletion_request_id};
    $ctx->{pending_request} = $newer;

    is_deeply(
        _ids(
            'deletion_request_id',
            $review->pending_deletion_requests( { limit => $REVIEW_LIMIT } )
        ),
        [ $oldest, $newer ],
        'pending review lists only pending requests, oldest first'
    );
    is_deeply(
        _ids(
            'deletion_request_id',
            $review->pending_deletion_requests( { limit => 1 } )
        ),
        [$oldest],
        'pending review applies limit'
    );
    is(
        $review->deletion_request( $ctx->{request} )
          ->get_column('deletion_request_id'),
        $ctx->{request},
        'review can load one deletion request'
    );
    is( $review->deletion_request( $ctx->{ids}->uuid ),
        undef, 'and finds nothing under an unknown id' );
    is_deeply(
        _ids(
            'deletion_request_id',
            $review->deletion_requests_for_user(
                $ctx->{users}{subject},
                { limit => $REVIEW_LIMIT }
            )
        ),
        [ $ctx->{request} ],
        'user dashboard lists own deletion requests'
    );
    is_deeply(
        $review->deletion_requests_for_user(
            $ctx->{requester}, { limit => $REVIEW_LIMIT }
        ),
        [],
        'and not one the member filed about someone else'
    );

    return;
}

sub _review_holds {
    my ($ctx) = @_;

    my $review = _reviewer($ctx);
    is(
        scalar @{
            $review->active_holds_for_user( $ctx->{users}{held},
                { limit => $REVIEW_LIMIT } )
        },
        1,
        'user dashboard lists active holds'
    );
    $ctx->{dbh}
      ->do( $HOLD_SQL, undef, $ctx->{ids}->uuid, _member( $ctx, 'released' ),
        $EARLY, $NOW, $ctx->{legal}, $EARLY );
    is_deeply(
        [
            sort @{
                _ids( 'retention_hold_id',
                    $review->active_holds( { limit => $REVIEW_LIMIT } ) )
            }
        ],
        [ sort @{$ctx}{qw(hold job_hold)} ],
        'staff review lists active holds, not ended ones'
    );
    is_deeply(
        [
            sort map { $_->[0] }
              @{ $ctx->{dbh}->selectall_arrayref($ACTIVE_HOLDS_SQL) }
        ],
        [ sort @{$ctx}{qw(hold job_hold)} ],
        'which are every active hold there is'
    );
    is( scalar @{ $review->active_holds( { limit => 1 } ) },
        1, 'staff hold review applies limit' );

    return;
}

sub _review_jobs {
    my ($ctx) = @_;

    my $review = _reviewer($ctx);
    is_deeply(
        _ids(
            'erasure_job_id',
            $review->erasure_jobs_by_status(
                'done', { limit => $REVIEW_LIMIT }
            )
        ),
        [ $ctx->{job} ],
        'completed erasure jobs can be reviewed'
    );

    # A second pending job, an hour after the blocked one.
    $ctx->{clock}->iso8601($LATER);
    my $later = _deletion($ctx)
      ->approve_request( $ctx->{pending_request}, $ctx->{staff}, 'verified' );
    $ctx->{clock}->iso8601($NOW);
    is_deeply(
        _ids(
            'erasure_job_id',
            $review->erasure_jobs_by_status(
                'pending', { limit => $REVIEW_LIMIT }
            )
        ),
        [ $ctx->{held_job}, $later->{job}{erasure_job_id} ],
        'job review filters status, earliest scheduled first'
    );
    is_deeply(
        _ids(
            'erasure_job_id',
            $review->erasure_jobs_by_status( 'pending', { limit => 1 } )
        ),
        [ $ctx->{held_job} ],
        'job review applies limit'
    );

    return;
}

# A member's exports, as their dashboard and the download route read them:
# only their own.
sub _export_review {
    my ($ctx) = @_;

    my $review    = _reviewer($ctx);
    my $subject   = $ctx->{users}{subject};
    my $bystander = $ctx->{users}{bystander};
    is_deeply(
        _ids(
            'export_request_id',
            $review->export_requests_for_user(
                $subject, { limit => $REVIEW_LIMIT }
            )
        ),
        [ $ctx->{export} ],
        'the member dashboard lists their exports'
    );
    my $completed =
      $review->completed_export_for_user( $subject, $ctx->{export} );
    is( $completed->get_column('export_request_id'),
        $ctx->{export}, 'a member can fetch their completed export' );
  TODO: {
        local $TODO = $MANIFEST_TODO;
        my $shown = GPForum::ViewModel::Privacy::Presenter->new->export_request(
            $completed);
        is( ref $shown->{manifest},
            'HASH', 'the dashboard reads the stored manifest decoded' );
    }
    is( $review->completed_export_for_user( $bystander, $ctx->{export} ),
        undef, 'another member cannot fetch it by its id' );

    my $pending = _exports($ctx)->request_user_export($bystander);
    is( $pending->{status}, 'pending', 'an export starts pending' );
    is(
        $review->completed_export_for_user(
            $bystander, $pending->{export_request_id}
        ),
        undef,
        'a pending export cannot be fetched'
    );
    is_deeply(
        _ids(
            'export_request_id',
            $review->pending_export_requests( { limit => $REVIEW_LIMIT } )
        ),
        [ $pending->{export_request_id} ],
        'staff review lists pending exports, not completed ones'
    );

    return;
}

# The export request store: one pending request per member and kind, which a
# retry reuses, until it completes.
sub _export_requests {
    my ($ctx) = @_;

    my $member  = _member( $ctx, 'exporter' );
    my $exports = _exports($ctx);
    my $first   = $exports->request_user_export($member);
    my $id      = $first->{export_request_id};
    ok(
        GPForum::Infrastructure::Id->is_uuid($id),
        'export request id is generated'
    );
    is( $first->{status}, 'pending', 'export starts pending' );
    is( _row( $ctx, $EXPORT_ROW_SQL, $id )->{status},
        'pending', 'export request row is inserted pending' );
    is_deeply( _trail( $ctx, 'privacy.export_requested', $member ),
        [@TRAIL], 'export request records its event, outbox and audit' );

    my $again = $exports->request_user_export($member);
    is( $again->{export_request_id},
        $id, 'retry reuses the pending export request' );
    is( _value( $ctx, $EXPORTS_SQL, $member ),
        1, 'retry does not insert a second export request' );
    is( _value( $ctx, $EVENTS_SQL, 'privacy.export_requested', $member ),
        1, 'retry does not emit a second export event' );

    $exports->complete_user_export($id);
    my $later = $exports->request_user_export($member);
    isnt( $later->{export_request_id},
        $id, 'a new export starts after the previous one completed' );
    is( _value( $ctx, $EXPORTS_SQL, $member ),
        2, 'completed export does not block a later request' );

    return;
}

# A concurrent request asks for the same export between this store's lookup
# and its insert: the store reuses the winner's request.
sub _export_request_race {
    my ($ctx) = @_;

    my $member = _member( $ctx, 'impatient' );
    my $winner;
    my $request = _racing(
        $ctx,
        'export_requests',
        sub {
            my ($rival) = @_;
            $winner =
              _exports( $ctx, schema => $rival )->request_user_export($member);
            return;
        },
        sub { return _exports($ctx)->request_user_export($member); }
    );
    is(
        $request->{export_request_id},
        $winner->{export_request_id},
        'unique race reuses the pending export request'
    );
    is( _value( $ctx, $EXPORTS_SQL, $member ),
        1, 'unique race does not insert a second export request' );
    is( _value( $ctx, $EVENTS_SQL, 'privacy.export_requested', $member ),
        1, 'unique race does not emit a second export event' );

    return;
}

# The id the store mints is another member's export: it mints a new one.
sub _export_id_collision {
    my ($ctx) = @_;

    my $other =
      _exports($ctx)->request_user_export( _member( $ctx, 'first-exporter' ) );
    my $taken     = $other->{export_request_id};
    my $requester = _member( $ctx, 'archivist' );
    my $subject   = _member( $ctx, 'archived' );
    my $request =
      _exports( $ctx,
        id_service => GPForum::Test::ScriptedId->new( next_ids => [$taken] ) )
      ->create_request(
        {
            export_type       => 'user_data',
            requester_user_id => $requester,
            subject_user_id   => $subject,
        }
      );
    my $id = $request->{export_request_id};
    ok( GPForum::Infrastructure::Id->is_uuid($id) && $id ne $taken,
        'unique export id collision remints the id' );
    is( $request->{requester_user_id},
        $requester, 'unique export id collision keeps this requester' );
    is( $request->{subject_user_id},
        $subject, 'unique export id collision keeps this subject' );
    is( _value( $ctx, $EXPORTS_SQL, $subject ),
        1, 'unique export id collision inserts this request' );
    is( _value( $ctx, $EVENTS_SQL, 'privacy.export_requested', $subject ),
        1, 'unique export id collision records this created event' );
    is(
        _row( $ctx, $EXPORT_ROW_SQL, $taken )->{subject_user_id},
        $other->{subject_user_id},
        'and leaves the other export alone'
    );

    return;
}

# The rival commits this very export, under the id the store is about to
# use, and dies before its event: the store keeps the request and records
# what the rival left out.
sub _export_id_race {
    my ($ctx) = @_;

    my $member  = _member( $ctx, 'half-exported' );
    my $id      = $ctx->{ids}->uuid;
    my $request = _racing(
        $ctx,
        'export_requests',
        sub {
            my ($rival) = @_;
            $rival->storage->dbh->do( $EXPORT_REQUEST_SQL,
                undef, $id, $member, $member, $NOW );
            return;
        },
        sub {
            return _exports( $ctx,
                id_service =>
                  GPForum::Test::ScriptedId->new( next_ids => [$id] ) )
              ->request_user_export($member);
        }
    );
    is( $request->{export_request_id},
        $id, 'leftover export id race keeps this request' );
    is( $request->{requester_user_id},
        $member, 'leftover export id race keeps this requester' );
    is( _value( $ctx, $EXPORTS_SQL, $member ),
        1, 'leftover export id race does not insert a second request' );
    is_deeply( _trail( $ctx, 'privacy.export_requested', $member ),
        [@TRAIL],
        'leftover export id race inserts the missing event, outbox and audit' );

    return;
}

# A member with more posts than a statement binds post ids: the bodies are
# read a batch at a time, and every post still arrives with its own body.
# libpq refuses more than 65,535 parameters in one statement; a batch of
# three over seven posts shows the batching without writing 65,536 posts.
sub _export_many_posts {
    my ($ctx) = @_;

    my $member = _member( $ctx, 'prolific' );
    my %body;
    for my $number ( 1 .. $MANY_POSTS ) {
        my $text = "Post number $number";
        $body{ _post( $ctx, $member, $text ) } = $text;
    }
    my $exports = _exports( $ctx, body_batch_size => $BODY_BATCH );
    my $request = $exports->request_user_export($member);
    my ( $done, $sent ) = _statements(
        $ctx, undef,
        sub {
            return $exports->complete_user_export(
                $request->{export_request_id} );
        }
    );
    is_deeply(
        {
            map { $_->{post_id} => $_->{body_source} }
              @{ $done->{manifest}{posts} }
        },
        \%body,
        'every post body arrives across batches'
    );
    is_deeply( _body_reads($sent), [@BATCH_BINDS],
        'and no statement binds more post ids than a batch' );
    is( $done->{manifest}{counts}{posts},
        $MANY_POSTS, 'the manifest counts every post' );

    my $quiet         = _member( $ctx, 'quiet' );
    my $quiet_request = $exports->request_user_export($quiet);
    my ( $quiet_done, $quiet_sent ) = _statements(
        $ctx, undef,
        sub {
            return $exports->complete_user_export(
                $quiet_request->{export_request_id} );
        }
    );
    is_deeply( $quiet_done->{manifest}{posts},
        [], 'a member with no posts exports none' );
    is_deeply( _body_reads($quiet_sent), [], 'and reads no bodies' );

    return;
}

# The export command replays from the command log: the same command id gets
# the stored answer, without a second bundle, and only for the member who
# sent it.
sub _commanded_export {
    my ($ctx) = @_;

    my $member = _member( $ctx, 'commander' );
    _post( $ctx, $member, 'Exported once' );
    my $workflow = _workflow($ctx);
    my %command  = ( command_id => 'export-command-1', user_id => $member );
    my $first    = $workflow->request_export( {%command} );
    ok( $first->{ok}, 'commanded export records the completed bundle' );
    is( _value( $ctx, $COMPLETED_EXPORTS_SQL, $member ),
        1, 'first commanded export creates and completes one request' );

    my $replayed = $workflow->request_export( {%command} );
    ok( $replayed->{ok}, 'same export command_id replays after complete' );
    is(
        $replayed->{stored}{export_request_id},
        $first->{stored}{export_request_id},
        'replayed export returns the original request'
    );
    is( _value( $ctx, $EXPORTS_SQL, $member ),
        1, 'replayed export does not create another bundle' );
    is_deeply( _trail( $ctx, 'privacy.export_completed', $member ),
        [@TRAIL], 'nor records another completion' );

    my $other  = _member( $ctx, 'borrower' );
    my $stolen = $workflow->request_export(
        { command_id => 'export-command-1', user_id => $other } );
    is( $stolen->{status}, 'conflict',
        'another member sending the same command id is refused' );
    is( $stolen->{stored}, undef, 'and is not handed the first export' );
    is( _value( $ctx, $EXPORTS_SQL, $other ),
        0, 'nor starts an export of their own' );

    my $fresh = $workflow->request_export(
        { command_id => 'export-command-2', user_id => $member } );
    ok( $fresh->{ok}, 'a new export command_id starts a later bundle' );
    isnt(
        $fresh->{stored}{export_request_id},
        $first->{stored}{export_request_id},
        'under a new request'
    );
    is( _value( $ctx, $COMPLETED_EXPORTS_SQL, $member ),
        2, 'a later export command creates and completes a second request' );

    return;
}

# A concurrent request asks for the same member's erasure between this
# store's lookup and its insert: the store reuses the winner's request.
sub _deletion_request_race {
    my ($ctx) = @_;

    my $member = _member( $ctx, 'twice' );
    my $winner;
    my $request = _racing(
        $ctx,
        'deletion_requests',
        sub {
            my ($rival) = @_;
            $winner = _deletion( $ctx, schema => $rival )
              ->request_deletion( _erase_request($member) );
            return;
        },
        sub {
            return _deletion($ctx)->request_deletion(
                _erase_request(
                    $member, undef, 'concurrent retry after lock miss'
                )
            );
        }
    );
    is(
        $request->{deletion_request_id},
        $winner->{deletion_request_id},
        'unique race reuses the open deletion request'
    );
    is( _value( $ctx, $REQUESTS_SQL, $member ),
        1, 'unique race does not insert a second deletion request' );
    is( _value( $ctx, $EVENTS_SQL, 'privacy.deletion_requested', $member ),
        1, 'unique race does not emit a second deletion event' );

    return;
}

# The id the store mints is another member's request: it mints a new one.
sub _deletion_id_collision {
    my ($ctx) = @_;

    my $other = _deletion($ctx)
      ->request_deletion( _erase_request( _member( $ctx, 'other' ) ) );
    my $taken  = $other->{deletion_request_id};
    my $member = _member( $ctx, 'collider' );
    my $request =
      _deletion( $ctx,
        id_service => GPForum::Test::ScriptedId->new( next_ids => [$taken] ) )
      ->request_deletion( _erase_request($member) );
    my $id = $request->{deletion_request_id};
    ok(
        GPForum::Infrastructure::Id->is_uuid($id) && $id ne $taken,
        'unique deletion id collision remints the id'
    );
    is( $request->{resource_id},
        $member, 'unique deletion id collision keeps this resource' );
    is( _value( $ctx, $REQUESTS_SQL, $member ),
        1, 'unique deletion id collision inserts this request' );
    is( _value( $ctx, $EVENTS_SQL, 'privacy.deletion_requested', $member ),
        1, 'unique deletion id collision records this created event' );
    is( _row( $ctx, $REQUEST_ROW_SQL, $taken )->{resource_id},
        $other->{resource_id}, 'and leaves the other request alone' );

    return;
}

# The rival commits this very request, under the id the store is about to
# use, and dies before its event: the store keeps the request and records
# what the rival left out.
sub _deletion_id_race {
    my ($ctx) = @_;

    my $member  = _member( $ctx, 'leftover' );
    my $id      = $ctx->{ids}->uuid;
    my $request = _racing(
        $ctx,
        'deletion_requests',
        sub {
            my ($rival) = @_;
            $rival->storage->dbh->do( $DELETION_REQUEST_SQL,
                undef, $id, $member, $member, $NOW );
            return;
        },
        sub {
            return _deletion( $ctx,
                id_service =>
                  GPForum::Test::ScriptedId->new( next_ids => [$id] ) )
              ->request_deletion( _erase_request($member) );
        }
    );
    is( $request->{deletion_request_id},
        $id, 'leftover deletion id race keeps this request' );
    is( $request->{resource_id},
        $member, 'leftover deletion id race keeps this resource' );
    is( _value( $ctx, $REQUESTS_SQL, $member ),
        1, 'leftover deletion id race does not insert a second request' );
    is_deeply(
        _trail( $ctx, 'privacy.deletion_requested', $member ),
        [@TRAIL],
        'leftover deletion id race inserts the missing event, outbox and audit'
    );

    return;
}

# The id the store mints for the job is another request's job.
sub _erasure_id_collision {
    my ($ctx) = @_;

    my $staff = _member( $ctx, 'approver' );
    my $other = _approved( $ctx, _member( $ctx, 'first-in-line' ), $staff );
    my $taken = $other->{job}{erasure_job_id};
    my $id    = _requested( $ctx, _member( $ctx, 'second-in-line' ) );
    my $approved =
      _deletion( $ctx,
        id_service => GPForum::Test::ScriptedId->new( next_ids => [$taken] ) )
      ->approve_request( $id, $staff, 'verified account owner request' );
    ok( $approved->{ok}, 'unique erasure id collision remints and approves' );
    ok( !$approved->{idempotent},
        'unique erasure id collision does not replay another job' );
    my $job = $approved->{job}{erasure_job_id};
    ok( GPForum::Infrastructure::Id->is_uuid($job) && $job ne $taken,
        'unique erasure id collision remints the id' );
    is( $approved->{request_id},
        $id, 'unique erasure id collision keeps this request' );
    is( _value( $ctx, $JOBS_SQL, $id ),
        1, 'unique erasure id collision inserts this job' );
    is( _row( $ctx, $JOB_ROW_SQL, $taken )->{deletion_request_id},
        $other->{request_id}, 'and leaves the other job alone' );
    $ctx->{approver}     = $staff;
    $ctx->{other_action} = $other->{action}{deletion_action_id};

    return;
}

# This request's job is already there, under the id the store is about to
# use, without its approval -- an approval that died after the insert. The
# lookup misses it, as it would a job committed just after it looked: the
# store reuses the job and records the missing approval.
sub _erasure_id_race {
    my ($ctx) = @_;

    my $id  = _requested( $ctx, _member( $ctx, 'half-approved' ) );
    my $job = $ctx->{ids}->uuid;
    $ctx->{dbh}->do( $ERASURE_JOB_SQL, undef, $job, $id, $NOW );
    my ( $approved, $sent ) = _statements(
        $ctx, undef,
        sub {
            return _deletion(
                $ctx,
                id_service =>
                  GPForum::Test::ScriptedId->new( next_ids => [$job] ),
                schema => GPForum::Test::RacedSchema->new(
                    misses => { ErasureJob => 1 },
                    schema => $ctx->{schema},
                ),
            )->approve_request( $id, $ctx->{approver}, 'verified' );
        }
    );
    is( _inserts( $sent, 'erasure_jobs' ),
        1, 'the raced approval tries to insert the job again' );
    ok( $approved->{ok},
        'leftover erasure id race reuses this job and finishes approval' );
    ok( !$approved->{idempotent},
        'leftover erasure id race does not skip the missing action' );
    is( $approved->{job}{erasure_job_id},
        $job, 'leftover erasure id race keeps this job' );
    is( $approved->{request_id},
        $id, 'leftover erasure id race keeps this request' );
    is( _value( $ctx, $JOBS_SQL, $id ),
        1, 'leftover erasure id race does not insert a second job' );
    is_deeply(
        [
            map { $_->[0] } @{
                $ctx->{dbh}->selectall_arrayref( $ACTION_TYPES_SQL, undef, $id )
            }
        ],
        ['released'],
        'leftover erasure id race inserts the missing approval action'
    );
    is( _row( $ctx, $REQUEST_ROW_SQL, $id )->{status},
        'approved', 'and approves the request' );

    return;
}

# The id the store mints for a held action is another request's action.
sub _action_id_collision {
    my ($ctx) = @_;

    my $taken = $ctx->{other_action};
    my $id    = _requested( $ctx, _member( $ctx, 'on-hold' ) );
    my $held =
      _deletion( $ctx,
        id_service => GPForum::Test::ScriptedId->new( next_ids => [$taken] ) )
      ->hold_request( $id, $ctx->{approver}, 'legal hold',
        { retention_hold_id => $ctx->{ids}->uuid } );
    ok( $held->{ok}, 'unique deletion action id collision remints and holds' );
    my $action = $held->{action}{deletion_action_id};
    ok(
        GPForum::Infrastructure::Id->is_uuid($action) && $action ne $taken,
        'unique deletion action id collision remints the id'
    );
    is( $held->{action}{deletion_request_id},
        $id, 'unique deletion action id collision keeps this request' );
    is( _value( $ctx, $ACTIONS_SQL, $id ),
        1, 'unique deletion action id collision inserts this action' );
    is( _row( $ctx, $ACTION_ROW_SQL, $taken )->{action_type},
        'released', 'and leaves the other action alone' );

    return;
}

# A concurrent request holds the same member between this store's lookup
# and its insert: the store returns the winner's hold.
sub _hold_race {
    my ($ctx) = @_;

    my $member = _member( $ctx, 'contested' );
    my $staff  = _member( $ctx, 'counsel' );
    my $winner;
    my $hold = _racing(
        $ctx,
        'retention_holds',
        sub {
            my ($rival) = @_;
            $winner = _holds( $ctx, schema => $rival )
              ->create_hold( _hold_input( $member, $staff ) );
            return;
        },
        sub {
            return _holds($ctx)->create_hold(
                _hold_input(
                    $member, $staff, 'concurrent hold after lookup miss'
                )
            );
        }
    );
    is(
        $hold->{retention_hold_id},
        $winner->{retention_hold_id},
        'unique race reuses the active retention hold'
    );
    is( _value( $ctx, $HOLDS_SQL, $member ),
        1, 'unique race does not insert a second retention hold' );
    is(
        _value( $ctx, $EVENTS_SQL, 'privacy.retention_hold_created', $member ),
        1,
        'unique race does not record a second hold event'
    );
    $ctx->{counsel}    = $staff;
    $ctx->{taken_hold} = $winner->{retention_hold_id};

    return;
}

sub _hold_id_collision {
    my ($ctx) = @_;

    my $taken  = $ctx->{taken_hold};
    my $member = _member( $ctx, 'next-case' );
    my $hold =
      _holds( $ctx,
        id_service => GPForum::Test::ScriptedId->new( next_ids => [$taken] ) )
      ->create_hold( _hold_input( $member, $ctx->{counsel} ) );
    my $id = $hold->{retention_hold_id};
    ok( GPForum::Infrastructure::Id->is_uuid($id) && $id ne $taken,
        'unique hold id collision remints the id' );
    is( $hold->{resource_id}, $member,
        'unique hold id collision keeps this resource' );
    is( _value( $ctx, $HOLDS_SQL, $member ),
        1, 'unique hold id collision inserts this hold' );
    is(
        _value( $ctx, $EVENTS_SQL, 'privacy.retention_hold_created', $member ),
        1,
        'unique hold id collision records this created event'
    );

    return;
}

# The rival commits this very hold under the id the store is about to use,
# and dies before its event.
sub _hold_id_race {
    my ($ctx) = @_;

    my $member = _member( $ctx, 'half-held' );
    my $id     = $ctx->{ids}->uuid;
    my $hold   = _racing(
        $ctx,
        'retention_holds',
        sub {
            my ($rival) = @_;
            $rival->storage->dbh->do( $HOLD_SQL, undef, $id, $member, $NOW,
                undef, $ctx->{counsel}, $NOW );
            return;
        },
        sub {
            return _holds( $ctx,
                id_service =>
                  GPForum::Test::ScriptedId->new( next_ids => [$id] ) )
              ->create_hold( _hold_input( $member, $ctx->{counsel} ) );
        }
    );
    is( $hold->{retention_hold_id},
        $id, 'leftover hold id race keeps this hold' );
    is( $hold->{resource_id}, $member,
        'leftover hold id race keeps this resource' );
    is( _value( $ctx, $HOLDS_SQL, $member ),
        1, 'leftover hold id race does not insert a second hold' );
    is_deeply( _trail( $ctx, 'privacy.retention_hold_created', $member ),
        [@TRAIL],
        'leftover hold id race inserts the missing event, outbox and audit' );

    return;
}

# A hold stops the job, and ends: the job runs again, an hour on, and
# erases the member as it would have without the hold.
sub _hold_ends {
    my ($ctx) = @_;

    my $member     = _member( $ctx, 'cleared' );
    my $credential = _credential( $ctx, $member );
    my $approved   = _approved( $ctx, $member, $ctx->{approver} );
    my ( $id, $job ) =
      ( $approved->{request_id}, $approved->{job}{erasure_job_id} );
    my $hold =
      _holds($ctx)->create_hold( _hold_input( $member, $ctx->{counsel} ) );
    my $blocked = _deletion($ctx)->complete_job( $job, $ctx->{approver} );
    is( $blocked->{error}, $HOLD_ERROR,
        'a hold placed after approval stops the job' );

    $ctx->{dbh}->do(
        'UPDATE retention_holds SET ends_at = ? WHERE retention_hold_id = ?',
        undef, $LATER, $hold->{retention_hold_id} );
    $ctx->{clock}->iso8601($LATER);
    my $erased = _deletion($ctx)->complete_job( $job, $ctx->{approver} );
    $ctx->{clock}->iso8601($NOW);
    ok( $erased->{ok}, 'and lets it run once the hold has ended' );
    is_deeply(
        $erased->{anonymized},
        { idempotent => 0, user_id => $member },
        'which anonymizes the member'
    );
    is_deeply(
        [
            @{ _row( $ctx, $USER_ROW_SQL, $member ) }{qw(display_name status)},
            _utc(
                $ctx,
                _row( $ctx, $CREDENTIAL_ROW_SQL, $credential )->{revoked_at}
            ),
        ],
        [ 'Deleted member', 'deleted', $LATER ],
        'erasing their identity and revoking their credentials'
    );
    is_deeply(
        [
            _row( $ctx, $JOB_ROW_SQL,     $job )->{status},
            _row( $ctx, $REQUEST_ROW_SQL, $id )->{status},
        ],
        [qw(done completed)],
        'the job is done and the held request completed'
    );
    is_deeply( _trail( $ctx, 'privacy.erasure_completed', $member ),
        [@TRAIL], 'the erasure records its event, outbox and audit' );

    return;
}

# The erasure's last write fails after the member was anonymized and their
# session revoked: the step rolls back whole, and the job, run again,
# erases the member and records it once.
sub _erasure_rolls_back {
    my ($ctx) = @_;

    my $member   = _member( $ctx, 'interrupted' );
    my $session  = _session( $ctx, $member );
    my $approved = _approved( $ctx, $member, $ctx->{approver} );
    my ( $id, $job ) =
      ( $approved->{request_id}, $approved->{job}{erasure_job_id} );
    $ctx->{dbh}->do($REFUSE_AUDIT_FUNCTION_SQL);
    $ctx->{dbh}->do($REFUSE_AUDIT_TRIGGER_SQL);
    my $ran =
      eval { _deletion($ctx)->complete_job( $job, $ctx->{approver} ); 1 };
    my $error = $EVAL_ERROR;
    $ctx->{dbh}->do($ALLOW_AUDIT_SQL);
    ok(
        !$ran && $error =~ /audit [ ] write [ ] failed/msx,
        'an erasure whose audit entry is refused fails'
    );
    is_deeply(
        [
            @{ _row( $ctx, $USER_ROW_SQL, $member ) }
              {qw(email_normalized status deleted_at)},
            _row( $ctx, $SESSION_ROW_SQL, $session )->{revoked_at},
            _row( $ctx, $JOB_ROW_SQL,     $job )->{status},
            _row( $ctx, $REQUEST_ROW_SQL, $id )->{status},
            _value( $ctx, $ACTIONS_SQL, $id ),
            _value( $ctx, $EVENTS_SQL,  'privacy.erasure_completed', $member ),
        ],
        [
            'interrupted@example.test', 'active',   undef, undef,
            'pending',                  'approved', 1,     0,
        ],
        'and rolls back the anonymization, the revocation and the completion'
    );

    my $retried = _deletion($ctx)->complete_job( $job, $ctx->{approver} );
    ok( $retried->{ok}, 'the job, run again, erases the member' );
    is_deeply(
        [
            _row( $ctx, $USER_ROW_SQL, $member )->{status},
            _utc(
                $ctx, _row( $ctx, $SESSION_ROW_SQL, $session )->{revoked_at}
            ),
            @{ _trail( $ctx, 'privacy.erasure_completed', $member ) },
        ],
        [ 'deleted', $NOW, @TRAIL ],
        'revokes the session and records the erasure once'
    );

    return;
}

# The workflow's answers over the real stores: what t/101 pins against a
# double of them, here from what the stores really return.
sub _workflow_outcomes {
    my ($ctx) = @_;

    my $workflow  = _workflow($ctx);
    my $staff     = $ctx->{approver};
    my %by_staff  = ( actor_user_id => $staff, reason => 'reviewed' );
    my $member    = _member( $ctx, 'leaver' );
    my $requested = $workflow->request_deletion(
        {
            command_id => 'deletion-command-1',
            reason     => 'leaving service',
            user_id    => $member,
        }
    );
    ok( $requested->{ok},
        'request_deletion succeeds when a reason is present' );
    is( $requested->{stored}{request_type},
        'anonymize', 'request_deletion stores an anonymize request' );
    my $approved = $workflow->approve_deletion(
        {
            %by_staff,
            command_id => 'approve-command-1',
            request_id => $requested->{stored}{deletion_request_id},
        }
    );
    ok( $approved->{ok}, 'approve_deletion succeeds for a known request' );
    is(
        $workflow->approve_deletion(
            {
                %by_staff,
                command_id => 'missing-approve-command-1',
                request_id => $ctx->{ids}->uuid,
            }
        )->{status},
        'not_found',
        'approve_deletion maps a missing request to not_found'
    );
    my $erased = $workflow->run_erasure_job(
        {
            actor_user_id => $staff,
            command_id    => 'erasure-command-1',
            job_id        => $approved->{stored}{job}{erasure_job_id},
        }
    );
    ok( $erased->{ok}, 'run_erasure_job succeeds for a known job' );
    is(
        $workflow->run_erasure_job(
            {
                actor_user_id => $staff,
                command_id    => 'missing-erasure-command-1',
                job_id        => $ctx->{ids}->uuid,
            }
        )->{status},
        'not_found',
        'run_erasure_job maps a missing job to not_found'
    );
    _workflow_holds( $ctx, $workflow );

    return;
}

sub _workflow_holds {
    my ( $ctx, $workflow ) = @_;

    my $staff  = $ctx->{approver};
    my $keeper = _member( $ctx, 'keeper' );
    my $job    = _approved( $ctx, $keeper, $staff );
    my %hold   = (
        actor_user_id => $staff,
        reason        => 'legal hold',
        request_id    => $job->{request_id},
    );
    my $held =
      $workflow->hold_deletion( { %hold, command_id => 'hold-command-1' } );
    ok( $held->{ok}, 'hold_deletion succeeds for a known request' );
    is( $held->{stored}{action}{action_type},
        'held', 'hold_deletion records a held action' );

    # Held again, by another command: the hold and the held request are
    # there already, and nothing more is written.
    my $again =
      $workflow->hold_deletion( { %hold, command_id => 'hold-command-2' } );
    ok( $again->{ok}, 'hold_deletion of a held request succeeds' );
    is( $again->{stored}{action}, undef, 'and records no second held action' );
    is_deeply(
        [
            _value( $ctx, $ACTIONS_SQL, $job->{request_id} ),
            _value( $ctx, $HOLDS_SQL,   $keeper ),
            @{ _trail( $ctx, 'privacy.deletion_held', $keeper ) },
        ],
        [ 2, 1, @TRAIL ],
        'nor a second hold, held action or hold event'
    );
    is(
        $workflow->hold_deletion(
            {
                actor_user_id => $staff,
                command_id    => 'missing-hold-command-1',
                reason        => 'legal hold',
                request_id    => $ctx->{ids}->uuid,
            }
        )->{status},
        'not_found',
        'hold_deletion maps a missing request to not_found'
    );
    is(
        $workflow->run_erasure_job(
            {
                actor_user_id => $staff,
                command_id    => 'erasure-held-command-1',
                job_id        => $job->{job}{erasure_job_id},
            }
        )->{status},
        'conflict',
        'run_erasure_job maps an active hold to conflict'
    );

    return;
}

sub _requested {
    my ( $ctx, $member ) = @_;

    return _deletion($ctx)->request_deletion( _erase_request($member) )
      ->{deletion_request_id};
}

sub _approved {
    my ( $ctx, $member, $staff ) = @_;

    return _deletion($ctx)
      ->approve_request( _requested( $ctx, $member ), $staff, 'verified' );
}

# How the rival connection finds the request row: 55P03 while another
# transaction holds a lock it cannot share, nothing when it could take it.
sub _lock_state {
    my ( $ctx, $id ) = @_;

    my $dbh   = $ctx->{rival}->storage->dbh;
    my $taken = eval { $dbh->selectrow_array( $LOCK_SQL, undef, $id ); 1 };

    return $taken ? q{} : $dbh->state;
}

# The post ids each body read binds, statement by statement.
sub _body_reads {
    my ($sent) = @_;

    my @reads;
    for my $statement ( @{$sent} ) {
        next
          if $statement !~ /\A SELECT [ ] .* [ ] FROM [ ] post_bodies [ ]/msx;
        my ($list) = $statement =~ /post_id [ ] IN [ ] [(] ([^)]*) [)]/msx;
        push @reads, scalar( () = ( $list // q{} ) =~ /[?]/gmsx );
    }

    return \@reads;
}

sub _inserts {
    my ( $sent, $table ) = @_;

    return scalar grep { $_ eq $table } _inserted_tables($sent);
}

# The table each INSERT wrote, in the order they were sent.
sub _inserted_tables {
    my ($sent) = @_;

    return map { /\A INSERT [ ] INTO [ ] (\w+) [ ]/msx ? ($1) : () } @{$sent};
}

# The event, outbox message and audit row an action recorded about a
# subject, counted.
sub _trail {
    my ( $ctx, $action, $subject ) = @_;

    return [
        _value( $ctx, $EVENTS_SQL, $action, $subject ),
        _value( $ctx, $OUTBOX_SQL, $action, $subject ),
        _value( $ctx, $AUDITS_SQL, $action, $subject ),
    ];
}

sub _ids {
    my ( $column, $rows ) = @_;

    return [ map { $_->get_column($column) } @{$rows} ];
}

# A manifest as a hash, whether it came back decoded or as the column's text.
sub _manifest {
    my ($manifest) = @_;

    return ref $manifest ? $manifest : decode_json($manifest);
}

sub _racing {
    my ( $ctx, $table, $rival, $code ) = @_;

    my $pending = 1;
    my ($result) = _statements(
        $ctx,
        sub {
            my ($statement) = @_;
            if (   $pending
                && $statement =~ /\A INSERT [ ] INTO [ ] \Q$table\E [ ]/msx )
            {
                $pending = 0;
                $rival->( $ctx->{rival} );
            }
            return;
        },
        $code
    );
    ok( !$pending, "the rival committed before the $table insert" );

    return $result;
}

# What $code returns, and the statements it sends through DBIx::Class, in
# order; $watch, when given, sees each before it is sent.
sub _statements {
    my ( $ctx, $watch, $code ) = @_;

    my @sent;
    my $storage = $ctx->{schema}->storage;
    $storage->debugcb(
        sub {
            my ( undef, $statement ) = @_;
            push @sent, $statement;
            if ($watch) {
                $watch->($statement);
            }
            return;
        }
    );
    $storage->debug(1);
    my $result = eval { return $code->() };
    my $error  = $EVAL_ERROR;
    $storage->debug(0);
    $storage->debugcb(undef);
    croak $error if $error;

    return ( $result, \@sent );
}

sub _version {
    my ( $ctx, $table, $key ) = @_;

    return _value( $ctx, $VERSION_SQL{$table}, $key );
}

sub _utc {
    my ( $ctx, $timestamp ) = @_;

    return _value( $ctx, $UTC_SQL, $timestamp );
}

sub _row {
    my ( $ctx, $sql, @bind ) = @_;

    return $ctx->{dbh}->selectrow_hashref( $sql, undef, @bind ) // {};
}

sub _value {
    my ( $ctx, $sql, @bind ) = @_;

    return scalar $ctx->{dbh}->selectrow_array( $sql, undef, @bind );
}

1;
