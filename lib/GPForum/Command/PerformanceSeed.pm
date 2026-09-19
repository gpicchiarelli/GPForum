package GPForum::Command::PerformanceSeed;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use DateTime;
use Digest::SHA   qw(sha256_hex);
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base;

use GPForum::Config;
use GPForum::Schema;

our $VERSION = '0.001';

const my $DEFAULT_USERS            => 5;
const my $DEFAULT_CATEGORIES       => 3;
const my $DEFAULT_THREADS          => 12;
const my $DEFAULT_POSTS_PER_THREAD => 8;
const my $PROFILE_SMALL            => 'small';
const my $PROFILE_MEDIUM           => 'medium';
const my $PROFILE_HOT_THREAD       => 'hot-thread';
const my $FAMILY_SPACE             => 0x1000;
const my $FAMILY_CATEGORY          => 0x1001;
const my $FAMILY_USER              => 0x1002;
const my $FAMILY_SESSION           => 0x1003;
const my $FAMILY_THREAD            => 0x1004;
const my $FAMILY_POST              => 0x1005;
const my $FAMILY_BODY              => 0x1006;
const my $FAMILY_REVISION          => 0x1007;
const my $FAMILY_SEARCH            => 0x1008;
const my $FAMILY_NOTIFICATION      => 0x1009;
const my $FAMILY_ROLE              => 0x100a;
const my $FAMILY_PERMISSION        => 0x100b;
const my $FAMILY_ROLE_BINDING      => 0x100c;
const my $FAMILY_BOOKMARK          => 0x100d;
const my $FAMILY_SUBSCRIPTION      => 0x100e;
const my $FAMILY_REPORT            => 0x100f;
const my $FAMILY_MODERATION_ACTION => 0x1010;
const my $HTTP_EXIT_USAGE          => 2;
const my $SEARCH_DOCUMENT_VERSION  => 1;
const my $THREAD_VERSION           => 1;
const my $SPACE_ID                 => _uuid( $FAMILY_SPACE, 1 );
const my $PASSWORD_HASH =>
  q{$argon2id$v=19$m=65536,t=3,p=1$gpforum$performance-seed};

has schema => undef;

sub run {
    my ( $self, @arguments ) = @_;

    my $options = _options(@arguments);
    return _print_usage()                             if $options->{help};
    return _print_report( _plan($options), $options ) if $options->{dry_run};

    my $report = eval { return $self->seed($options); };
    if ( !$report ) {
        print {*STDERR} _seed_error($EVAL_ERROR);
        return $HTTP_EXIT_USAGE;
    }

    return _print_report( $report, $options );
}

sub seed {
    my ( $self, $options ) = @_;

    my $plan = _plan($options);
    my $dbh  = $self->_dbh;

    _assert_migrated($dbh);
    _with_transaction( $dbh, sub { _insert_dataset( $dbh, $plan ); } );

    return $plan;
}

sub _dbh {
    my ($self) = @_;

    my $schema = $self->schema;
    if ( !$schema ) {
        my $config = GPForum::Config->from_environment;
        $schema = GPForum::Schema->connect_from_config($config);
    }

    return $schema->storage->dbh;
}

sub _with_transaction {
    my ( $dbh, $code ) = @_;

    $dbh->begin_work;
    my $ok = eval {
        $dbh->do('SET CONSTRAINTS ALL DEFERRED');
        $code->();
        $dbh->commit;
        return 1;
    };
    if ( !$ok ) {
        my $error = $EVAL_ERROR;
        eval { $dbh->rollback; 1 };
        croak $error;
    }

    return;
}

sub _insert_dataset {
    my ( $dbh, $plan ) = @_;

    _clear_performance_dataset($dbh);
    _insert_space($dbh);
    _insert_users( $dbh, $plan );
    _insert_roles_and_permissions( $dbh, $plan );
    _insert_sessions( $dbh, $plan );
    _insert_categories( $dbh, $plan );
    _insert_threads_and_posts( $dbh, $plan );
    _insert_category_stats( $dbh, $plan );
    _insert_read_state( $dbh, $plan );
    _insert_bookmarks( $dbh, $plan );
    _insert_subscriptions( $dbh, $plan );
    _insert_notifications( $dbh, $plan );
    _insert_feed_items( $dbh, $plan );
    _insert_reports( $dbh, $plan );
    _insert_moderation_actions( $dbh, $plan );

    return;
}

sub _clear_performance_dataset {
    my ($dbh) = @_;

    my @statements = (
        [
q{DELETE FROM moderation_actions WHERE moderation_action_id::text LIKE '018f1010-%'}
        ],
        [q{DELETE FROM reports WHERE report_id::text LIKE '018f100f-%'}],
        [
            q{
                DELETE FROM notification_inbox
                 WHERE notification_id::text LIKE '018f1009-%'
            }
        ],
        [
q{DELETE FROM notifications WHERE notification_id::text LIKE '018f1009-%'}
        ],
        [
            q{
                DELETE FROM user_feed_items
                 WHERE user_id::text LIKE '018f1002-%'
                    OR item_id::text LIKE '018f1004-%'
            }
        ],
        [
q{DELETE FROM subscriptions WHERE subscription_id::text LIKE '018f100e-%'}
        ],
        [q{DELETE FROM bookmarks WHERE bookmark_id::text LIKE '018f100d-%'}],
        [
            q{
                DELETE FROM user_read_marker_deltas
                 WHERE user_id::text LIKE '018f1002-%'
                    OR thread_id::text LIKE '018f1004-%'
            }
        ],
        [
            q{
                DELETE FROM thread_read_state
                 WHERE user_id::text LIKE '018f1002-%'
                    OR thread_id::text LIKE '018f1004-%'
            }
        ],
        [
q{DELETE FROM thread_counters WHERE thread_id::text LIKE '018f1004-%'}
        ],
        [ q{DELETE FROM search_documents WHERE space_id = ?}, $SPACE_ID ],
        [
q{DELETE FROM post_revisions WHERE revision_id::text LIKE '018f1007-%'}
        ],
        [q{DELETE FROM post_bodies WHERE body_id::text LIKE '018f1006-%'}],
        [q{DELETE FROM posts WHERE post_id::text LIKE '018f1005-%'}],
        [q{DELETE FROM threads WHERE thread_id::text LIKE '018f1004-%'}],
        [
q{DELETE FROM category_stats WHERE category_id::text LIKE '018f1001-%'}
        ],
        [ q{DELETE FROM categories WHERE space_id = ?}, $SPACE_ID ],
        [q{DELETE FROM role_bindings WHERE binding_id::text LIKE '018f100c-%'}],
        [q{DELETE FROM sessions WHERE session_id::text LIKE '018f1003-%'}],
        [q{DELETE FROM users WHERE id::text LIKE '018f1002-%'}],
        [ q{DELETE FROM spaces WHERE space_id = ?}, $SPACE_ID ],
    );

    for my $statement (@statements) {
        my ( $sql, @bind ) = @{$statement};
        $dbh->do( $sql, undef, @bind );
    }

    return;
}

sub _insert_space {
    my ($dbh) = @_;

    $dbh->do(
        q{
            INSERT INTO spaces
                (space_id, slug, title, description, visibility, position,
                 created_at, updated_at)
            VALUES (?, 'performance', 'Performance Lab',
                    'Deterministic performance benchmark space',
                    'public', 1, ?, ?)
            ON CONFLICT (space_id) DO UPDATE SET
                title = EXCLUDED.title,
                description = EXCLUDED.description,
                updated_at = EXCLUDED.updated_at
        },
        undef, $SPACE_ID, _timestamp(0), _timestamp(0),
    );

    return;
}

sub _insert_users {
    my ( $dbh, $plan ) = @_;

    for my $number ( 1 .. $plan->{dataset}{users} ) {
        $dbh->do(
            q{
                INSERT INTO users
                    (id, username, display_name, email_normalized,
                     password_hash, status, trust_level, email_verified_at,
                     created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET
                    display_name = EXCLUDED.display_name,
                    status = EXCLUDED.status,
                    updated_at = EXCLUDED.updated_at
            },
            undef,
            _user_id($number),
            'perf_user_' . $number,
            'Performance User ' . $number,
            'perf_user_' . $number . '@example.invalid',
            $PASSWORD_HASH,
            $number % 4,
            _timestamp($number),
            _timestamp($number),
            _timestamp($number),
        );
    }

    return;
}

sub _insert_roles_and_permissions {
    my ( $dbh, $plan ) = @_;

    _insert_roles($dbh);
    _insert_permissions($dbh);
    _insert_role_permissions($dbh);
    _insert_role_bindings( $dbh, $plan );

    return;
}

sub _insert_roles {
    my ($dbh) = @_;

    my @roles = (
        [ 1, 'administrator', 'Performance administrator' ],
        [ 2, 'moderator',     'Performance moderator' ],
        [ 3, 'member',        'Performance member' ],
    );

    for my $role (@roles) {
        $dbh->do(
            q{
                INSERT INTO roles (role_id, name, description, created_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (role_id) DO UPDATE SET
                    name = EXCLUDED.name,
                    description = EXCLUDED.description
            },
            undef, _role_id( $role->[0] ), $role->[1], $role->[2],
            _timestamp(0),
        );
    }

    return;
}

sub _insert_permissions {
    my ($dbh) = @_;

    my @permissions = (
        [ 1, 'admin.view',        'admin',      'view' ],
        [ 2, 'role.manage',       'role',       'manage' ],
        [ 3, 'moderation.view',   'moderation', 'view' ],
        [ 4, 'moderation.action', 'moderation', 'action' ],
        [ 5, 'forum.write',       'forum',      'write' ],
        [ 6, 'report.create',     'report',     'create' ],
    );

    for my $permission (@permissions) {
        $dbh->do(
            q{
                INSERT INTO permissions
                    (permission_id, name, resource_type, action, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (permission_id) DO UPDATE SET
                    name = EXCLUDED.name,
                    resource_type = EXCLUDED.resource_type,
                    action = EXCLUDED.action
            },
            undef,
            _permission_id( $permission->[0] ),
            $permission->[1],
            $permission->[2],
            $permission->[3],
            _timestamp(0),
        );
    }

    return;
}

sub _insert_role_permissions {
    my ($dbh) = @_;

    my @role_permissions = (
        [ 1, 1 ], [ 1, 2 ], [ 1, 3 ], [ 1, 4 ], [ 1, 5 ], [ 1, 6 ],
        [ 2, 3 ], [ 2, 4 ], [ 2, 6 ], [ 3, 5 ], [ 3, 6 ],
    );

    for my $grant (@role_permissions) {
        $dbh->do(
            q{
                INSERT INTO role_permissions
                    (role_id, permission_id, created_at)
                VALUES (?, ?, ?)
                ON CONFLICT (role_id, permission_id) DO NOTHING
            },
            undef, _role_id( $grant->[0] ), _permission_id( $grant->[1] ),
            _timestamp(0),
        );
    }

    return;
}

sub _insert_role_bindings {
    my ( $dbh, $plan ) = @_;

    for my $user_number ( 1 .. $plan->{dataset}{users} ) {
        my $role_number = _role_number_for_user($user_number);
        $dbh->do(
            q{
                INSERT INTO role_bindings
                    (binding_id, user_id, role_id, resource_type, resource_id,
                     space_id, created_by_user_id, created_at)
                VALUES (?, ?, ?, 'space', NULL, ?, ?, ?)
                ON CONFLICT (binding_id) DO UPDATE SET
                    role_id = EXCLUDED.role_id,
                    revoked_at = NULL
            },
            undef,
            _uuid( $FAMILY_ROLE_BINDING, $user_number ),
            _user_id($user_number),
            _role_id($role_number),
            $SPACE_ID,
            _user_id(1),
            _timestamp($user_number),
        );
    }

    return;
}

sub _insert_sessions {
    my ( $dbh, $plan ) = @_;

    for my $number ( 1 .. $plan->{dataset}{users} ) {
        $dbh->do(
            q{
                INSERT INTO sessions
                    (session_id, user_id, session_hash, created_at,
                     last_seen_at, expires_at, ip_hash, user_agent_hash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (session_id) DO UPDATE SET
                    last_seen_at = EXCLUDED.last_seen_at,
                    expires_at = EXCLUDED.expires_at
            },
            undef,
            _uuid( $FAMILY_SESSION, $number ),
            _user_id($number),
            'performance-session-hash-' . $number,
            _timestamp($number),
            _timestamp( $number + 20 ),
            _timestamp( $number + 2_000 ),
            'ip-hash-' . $number,
            'ua-hash-' . $number,
        );
    }

    return;
}

sub _insert_categories {
    my ( $dbh, $plan ) = @_;

    for my $number ( 1 .. $plan->{dataset}{categories} ) {
        $dbh->do(
            q{
                INSERT INTO categories
                    (category_id, space_id, slug, title, description,
                     visibility, position, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'public', ?, ?, ?)
                ON CONFLICT (category_id) DO UPDATE SET
                    title = EXCLUDED.title,
                    description = EXCLUDED.description,
                    updated_at = EXCLUDED.updated_at
            },
            undef,
            _category_id($number),
            $SPACE_ID,
            'performance-' . $number,
            'Performance Category ' . $number,
            'Benchmark category ' . $number,
            $number,
            _timestamp($number),
            _timestamp($number),
        );
    }

    return;
}

sub _insert_threads_and_posts {
    my ( $dbh, $plan ) = @_;

    for my $thread_number ( 1 .. $plan->{dataset}{threads} ) {
        _insert_thread( $dbh, $plan, $thread_number );
        _insert_thread_posts( $dbh, $plan, $thread_number );
        _insert_thread_counter( $dbh, $plan, $thread_number );
        _insert_search_document( $dbh, $plan, $thread_number );
    }

    return;
}

sub _insert_thread {
    my ( $dbh, $plan, $thread_number ) = @_;

    $dbh->do(
        q{
            INSERT INTO threads
                (thread_id, category_id, author_user_id, title, slug, pinned,
                 visibility, moderation_state, last_activity_at, created_at,
                 updated_at)
            VALUES (?, ?, ?, ?, ?, false, 'public', 'visible', ?, ?, ?)
            ON CONFLICT (thread_id) DO UPDATE SET
                title = EXCLUDED.title,
                last_activity_at = EXCLUDED.last_activity_at,
                updated_at = EXCLUDED.updated_at
        },
        undef,
        _thread_id($thread_number),
        _category_id( _category_number( $plan, $thread_number ) ),
        _user_id( _user_number( $plan, $thread_number ) ),
        'Performance thread ' . $thread_number,
        'performance-thread-' . $thread_number,
        _timestamp( $thread_number + 100 ),
        _timestamp( $thread_number + 10 ),
        _timestamp( $thread_number + 100 ),
    );

    return;
}

sub _insert_thread_posts {
    my ( $dbh, $plan, $thread_number ) = @_;

    for my $position ( 1 .. $plan->{dataset}{posts_per_thread} ) {
        _insert_post( $dbh, $plan, $thread_number, $position );
    }

    return;
}

sub _insert_post {
    my ( $dbh, $plan, $thread_number, $position ) = @_;

    my $post_key    = _post_key( $plan, $thread_number, $position );
    my $post_id     = _uuid( $FAMILY_POST,     $post_key );
    my $body_id     = _uuid( $FAMILY_BODY,     $post_key );
    my $revision_id = _uuid( $FAMILY_REVISION, $post_key );
    my $body        = _post_body( $thread_number, $position );

    _insert_post_head( $dbh, $plan, $thread_number, $position, $post_id );
    _insert_post_body( $dbh, $post_id, $body_id, $body, $position );
    _insert_post_revision( $dbh, $plan, $post_id, $body_id, $revision_id );
    _update_post_current_version( $dbh, $post_id, $body_id, $revision_id );

    return;
}

sub _insert_post_head {
    my ( $dbh, $plan, $thread_number, $position, $post_id ) = @_;

    $dbh->do(
        q{
            INSERT INTO posts
                (post_id, thread_id, author_user_id, position, visibility,
                 moderation_state, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'public', 'visible', ?, ?)
            ON CONFLICT (post_id) DO UPDATE SET
                updated_at = EXCLUDED.updated_at
        },
        undef,
        $post_id,
        _thread_id($thread_number),
        _user_id( _user_number( $plan, $position ) ),
        $position,
        _timestamp( $thread_number + $position ),
        _timestamp( $thread_number + $position ),
    );

    return;
}

sub _insert_post_body {
    my ( $dbh, $post_id, $body_id, $body, $position ) = @_;

    $dbh->do(
        q{
            INSERT INTO post_bodies
                (body_id, post_id, body_format, body_source,
                 body_rendered_safe, source_hash, created_at)
            VALUES (?, ?, 'markdown', ?, ?, ?, ?)
            ON CONFLICT (body_id) DO UPDATE SET
                body_source = EXCLUDED.body_source,
                body_rendered_safe = EXCLUDED.body_rendered_safe,
                source_hash = EXCLUDED.source_hash
        },
        undef,
        $body_id,
        $post_id,
        $body,
        '<p>' . $body . '</p>',
        sha256_hex($body),
        _timestamp($position),
    );

    return;
}

sub _insert_post_revision {
    my ( $dbh, $plan, $post_id, $body_id, $revision_id ) = @_;

    $dbh->do(
        q{
            INSERT INTO post_revisions
                (revision_id, post_id, body_id, editor_user_id,
                 revision_number, edit_reason, created_at)
            VALUES (?, ?, ?, ?, 1, 'performance seed', ?)
            ON CONFLICT (revision_id) DO UPDATE SET
                edit_reason = EXCLUDED.edit_reason
        },
        undef,
        $revision_id,
        $post_id,
        $body_id,
        _user_id( _user_number( $plan, 1 ) ),
        _timestamp(1),
    );

    return;
}

sub _update_post_current_version {
    my ( $dbh, $post_id, $body_id, $revision_id ) = @_;

    $dbh->do(
        q{
            UPDATE posts
               SET current_body_id = ?,
                   current_revision_id = ?
             WHERE post_id = ?
        },
        undef, $body_id, $revision_id, $post_id,
    );

    return;
}

sub _insert_thread_counter {
    my ( $dbh, $plan, $thread_number ) = @_;

    my $last_position = $plan->{dataset}{posts_per_thread};
    my $reply_count   = $last_position - 1;

    $dbh->do(
        q{
            INSERT INTO thread_counters
                (thread_id, reply_count, visible_reply_count, last_post_id,
                 last_activity_at, reconciled_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (thread_id) DO UPDATE SET
                reply_count = EXCLUDED.reply_count,
                visible_reply_count = EXCLUDED.visible_reply_count,
                last_post_id = EXCLUDED.last_post_id,
                last_activity_at = EXCLUDED.last_activity_at,
                reconciled_at = EXCLUDED.reconciled_at
        },
        undef,
        _thread_id($thread_number),
        $reply_count,
        $reply_count,
        _uuid(
            $FAMILY_POST, _post_key( $plan, $thread_number, $last_position )
        ),
        _timestamp( $thread_number + 100 ),
        _timestamp( $thread_number + 100 ),
    );

    return;
}

sub _insert_search_document {
    my ( $dbh, $plan, $thread_number ) = @_;

    my $title = 'Performance thread ' . $thread_number;
    my $body  = 'Searchable performance baseline content for GPForum thread '
      . $thread_number;

    $dbh->do(
        q{
            INSERT INTO search_documents
                (search_document_id, entity_type, entity_id, category_id,
                 author_user_id, space_id, visibility, permission_scope,
                 visibility_version, permission_version, language, title, body,
                 search_vector, source_version, source_created_at, indexed_at)
            VALUES (?, 'thread', ?, ?, ?, ?, 'public', 'public', 1, 1,
                    'simple', ?, ?, to_tsvector('simple', ?), ?, ?, ?)
            ON CONFLICT (entity_type, entity_id) DO UPDATE SET
                category_id = EXCLUDED.category_id,
                author_user_id = EXCLUDED.author_user_id,
                title = EXCLUDED.title,
                body = EXCLUDED.body,
                search_vector = EXCLUDED.search_vector,
                source_created_at = EXCLUDED.source_created_at,
                indexed_at = EXCLUDED.indexed_at
        },
        undef,
        _uuid( $FAMILY_SEARCH, $thread_number ),
        _thread_id($thread_number),
        _category_id( _category_number( $plan, $thread_number ) ),
        _user_id( _user_number( $plan, $thread_number ) ),
        $SPACE_ID,
        $title,
        $body,
        $title . q{ } . $body,
        $SEARCH_DOCUMENT_VERSION,
        _timestamp( $thread_number + 100 ),
        _timestamp( $thread_number + 200 ),
    );

    return;
}

sub _insert_category_stats {
    my ( $dbh, $plan ) = @_;

    for my $number ( 1 .. $plan->{dataset}{categories} ) {
        my $threads = _threads_in_category( $plan, $number );
        my $posts   = $threads * $plan->{dataset}{posts_per_thread};
        $dbh->do(
            q{
                INSERT INTO category_stats
                    (category_id, thread_count, visible_thread_count,
                     post_count, reconciled_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (category_id) DO UPDATE SET
                    thread_count = EXCLUDED.thread_count,
                    visible_thread_count = EXCLUDED.visible_thread_count,
                    post_count = EXCLUDED.post_count,
                    reconciled_at = EXCLUDED.reconciled_at
            },
            undef, _category_id($number), $threads, $threads, $posts,
            _timestamp(300),
        );
    }

    return;
}

sub _insert_read_state {
    my ( $dbh, $plan ) = @_;

    for my $user_number ( 1 .. $plan->{dataset}{users} ) {
        _insert_read_state_for_user( $dbh, $plan, $user_number );
    }

    return;
}

sub _insert_read_state_for_user {
    my ( $dbh, $plan, $user_number ) = @_;

    my $limit = _minimum( $plan->{dataset}{threads}, 3 );
    for my $thread_number ( 1 .. $limit ) {
        _upsert_read_state( $dbh, $plan, $user_number, $thread_number );
    }

    return;
}

sub _upsert_read_state {
    my ( $dbh, $plan, $user_number, $thread_number ) = @_;

    my $position = _minimum( $plan->{dataset}{posts_per_thread}, 4 );
    for my $table (qw(thread_read_state user_read_marker_deltas)) {
        $dbh->do(
            qq{
                INSERT INTO $table
                    (user_id, thread_id, last_read_position, last_read_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (user_id, thread_id) DO UPDATE SET
                    last_read_position = EXCLUDED.last_read_position,
                    last_read_at = EXCLUDED.last_read_at
            },
            undef,     _user_id($user_number), _thread_id($thread_number),
            $position, _timestamp(400),
        );
    }

    return;
}

sub _insert_bookmarks {
    my ( $dbh, $plan ) = @_;

    for my $number ( 1 .. $plan->{dataset}{bookmarks} ) {
        $dbh->do(
            q{
                INSERT INTO bookmarks
                    (bookmark_id, user_id, target_type, target_id, note,
                     created_at)
                VALUES (?, ?, 'thread', ?, ?, ?)
                ON CONFLICT (user_id, target_type, target_id) DO UPDATE SET
                    note = EXCLUDED.note,
                    deleted_at = NULL
            },
            undef,
            _uuid( $FAMILY_BOOKMARK, $number ),
            _user_id( _user_number( $plan, $number ) ),
            _thread_id( _thread_number( $plan, $number ) ),
            'benchmark bookmark ' . $number,
            _timestamp( 450 + $number ),
        );
    }

    return;
}

sub _insert_subscriptions {
    my ( $dbh, $plan ) = @_;

    for my $number ( 1 .. $plan->{dataset}{subscriptions} ) {
        $dbh->do(
            q{
                INSERT INTO subscriptions
                    (subscription_id, user_id, target_type, target_id,
                     preference, created_at)
                VALUES (?, ?, 'thread', ?, 'all', ?)
                ON CONFLICT (user_id, target_type, target_id) DO UPDATE SET
                    preference = EXCLUDED.preference,
                    revoked_at = NULL
            },
            undef,
            _uuid( $FAMILY_SUBSCRIPTION, $number ),
            _user_id( _user_number( $plan, $number ) ),
            _thread_id( _thread_number( $plan, $number ) ),
            _timestamp( 470 + $number ),
        );
    }

    return;
}

sub _insert_notifications {
    my ( $dbh, $plan ) = @_;

    for my $number ( 1 .. $plan->{dataset}{notifications} ) {
        _insert_notification( $dbh, $plan, $number );
    }

    return;
}

sub _insert_notification {
    my ( $dbh, $plan, $number ) = @_;

    my $recipient = _user_id( _user_number( $plan, $number ) );
    my $thread_id = _thread_id( _thread_number( $plan, $number ) );
    my $created   = _timestamp( 500 + $number );
    my $payload   = encode_json( { thread_id => $thread_id } );
    my $id        = _uuid( $FAMILY_NOTIFICATION, $number );

    $dbh->do(
        q{
            INSERT INTO notifications
                (notification_id, recipient_user_id, source_type, source_id,
                 notification_type, payload, created_at)
            VALUES (?, ?, 'thread', ?, 'reply_created', ?::jsonb, ?)
            ON CONFLICT (notification_id, created_at) DO UPDATE SET
                payload = EXCLUDED.payload
        },
        undef, $id, $recipient, $thread_id, $payload, $created,
    );
    $dbh->do(
        q{
            INSERT INTO notification_inbox
                (recipient_user_id, notification_id, created_at, rank_score)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (recipient_user_id, notification_id) DO UPDATE SET
                rank_score = EXCLUDED.rank_score
        },
        undef, $recipient, $id, $created, $number,
    );

    return;
}

sub _insert_feed_items {
    my ( $dbh, $plan ) = @_;

    for my $thread_number ( 1 .. $plan->{dataset}{threads} ) {
        $dbh->do(
            q{
                INSERT INTO user_feed_items
                    (user_id, item_type, item_id, created_at, rank_score,
                     visibility_version, permission_version)
                VALUES (?, 'thread', ?, ?, ?, 1, 1)
                ON CONFLICT (user_id, item_type, item_id) DO UPDATE SET
                    rank_score = EXCLUDED.rank_score,
                    created_at = EXCLUDED.created_at
            },
            undef,
            _user_id( _user_number( $plan, $thread_number ) ),
            _thread_id($thread_number),
            _timestamp( 600 + $thread_number ),
            $THREAD_VERSION / $thread_number,
        );
    }

    return;
}

sub _insert_reports {
    my ( $dbh, $plan ) = @_;

    for my $number ( 1 .. $plan->{dataset}{reports} ) {
        my $target_type = $number % 2 ? 'thread' : 'post';
        my $target_id =
          $target_type eq 'thread'
          ? _thread_id( _thread_number( $plan, $number ) )
          : _uuid( $FAMILY_POST,
            _post_key( $plan, _thread_number( $plan, $number ), 1 ) );
        $dbh->do(
            q{
                INSERT INTO reports
                    (report_id, reporter_user_id, target_type, target_id,
                     reason, details, status, assigned_moderator_user_id,
                     created_at)
                VALUES (?, ?, ?, ?, 'spam', ?, 'open', ?, ?)
                ON CONFLICT (report_id) DO UPDATE SET
                    status = EXCLUDED.status,
                    details = EXCLUDED.details
            },
            undef,
            _uuid( $FAMILY_REPORT, $number ),
            _user_id( _user_number( $plan, $number ) ),
            $target_type,
            $target_id,
            'benchmark report ' . $number,
            _user_id( _minimum( $plan->{dataset}{users}, 2 ) ),
            _timestamp( 700 + $number ),
        );
    }

    return;
}

sub _insert_moderation_actions {
    my ( $dbh, $plan ) = @_;

    for my $number ( 1 .. $plan->{dataset}{moderation_actions} ) {
        $dbh->do(
            q{
                INSERT INTO moderation_actions
                    (moderation_action_id, actor_user_id, action_type,
                     target_type, target_id, reason, metadata, created_at)
                VALUES (?, ?, 'post.reviewed', 'post', ?, ?,
                        '{}'::jsonb, ?)
                ON CONFLICT (moderation_action_id) DO UPDATE SET
                    reason = EXCLUDED.reason,
                    metadata = EXCLUDED.metadata
            },
            undef,
            _uuid( $FAMILY_MODERATION_ACTION, $number ),
            _user_id( _minimum( $plan->{dataset}{users}, 2 ) ),
            _uuid(
                $FAMILY_POST,
                _post_key( $plan, _thread_number( $plan, $number ), 1 )
            ),
            'benchmark moderation action ' . $number,
            _timestamp( 730 + $number ),
        );
    }

    return;
}

sub _assert_migrated {
    my ($dbh) = @_;

    for my $table (
        qw(
        users roles permissions role_bindings categories threads posts
        thread_read_state bookmarks subscriptions reports moderation_actions
        )
      )
    {
        my $exists = $dbh->selectrow_array( q{SELECT to_regclass(?)},
            undef, 'public.' . $table );
        croak
'database schema is not migrated; run carton exec bin/gpforum-migrate --apply'
          if !$exists;
    }

    return;
}

sub _plan {
    my ($options) = @_;

    my $users            = $options->{users};
    my $categories       = $options->{categories};
    my $threads          = $options->{threads};
    my $posts_per_thread = $options->{posts_per_thread};
    my $posts            = $threads * $posts_per_thread;
    my $notifications    = $users * 3;
    my $bookmarks        = $users;
    my $subscriptions    = $users;
    my $reports          = _minimum( $threads, $users * 2 );
    my $moderation       = _minimum( $threads, $users );

    return {
        status  => $options->{dry_run} ? 'dry-run' : 'seeded',
        profile => $options->{profile},
        dataset => {
            users              => $users,
            categories         => $categories,
            threads            => $threads,
            posts_per_thread   => $posts_per_thread,
            posts              => $posts,
            sessions           => $users,
            roles              => 3,
            permissions        => 6,
            role_bindings      => $users,
            read_states        => $users * _minimum( $threads, 3 ),
            bookmarks          => $bookmarks,
            subscriptions      => $subscriptions,
            notifications      => $notifications,
            feed_items         => $threads,
            reports            => $reports,
            moderation_actions => $moderation,
        },
        routes => _routes(),
    };
}

sub _routes {
    return {
        home         => q{/},
        categories   => q{/categories},
        category     => q{/c/} . _category_id(1),
        thread       => q{/t/} . _thread_id(1),
        search       => q{/search?q=performance},
        health       => q{/health},
        health_ready => q{/health/ready},
        metrics      => q{/metrics},
    };
}

sub _options {
    my (@arguments) = @_;

    my $options = {
        users            => $DEFAULT_USERS,
        categories       => $DEFAULT_CATEGORIES,
        threads          => $DEFAULT_THREADS,
        posts_per_thread => $DEFAULT_POSTS_PER_THREAD,
        profile          => $PROFILE_SMALL,
        format           => 'text',
        dry_run          => 0,
        help             => 0,
    };

    while (@arguments) {
        _consume_option( $options, \@arguments );
    }
    _apply_profile($options);

    return $options;
}

sub _consume_option {
    my ( $options, $arguments ) = @_;

    my $argument = shift @{$arguments};
    my %handler  = (
        '--dry-run' => sub { $options->{dry_run} = 1; },
        '--json'    => sub { $options->{format}  = 'json'; },
        '--help'    => sub { $options->{help}    = 1; },
        '--profile' => sub {
            $options->{profile} = _profile( shift @{$arguments} );
        },
        '--users' => sub {
            $options->{users}   = _positive_integer( shift @{$arguments} );
            $options->{profile} = 'custom';
        },
        '--categories' => sub {
            $options->{categories} =
              _positive_integer( shift @{$arguments} );
            $options->{profile} = 'custom';
        },
        '--threads' => sub {
            $options->{threads} = _positive_integer( shift @{$arguments} );
            $options->{profile} = 'custom';
        },
        '--posts-per-thread' => sub {
            $options->{posts_per_thread} =
              _positive_integer( shift @{$arguments} );
            $options->{profile} = 'custom';
        },
    );

    my $handler = $handler{$argument};
    croak _usage() if !$handler;
    $handler->();

    return;
}

sub _print_report {
    my ( $report, $options ) = @_;

    my $text =
      $options->{format} eq 'json'
      ? encode_json($report) . "\n"
      : _text_report($report);

    print $text or croak 'failed to write performance seed report';

    return 0;
}

sub _text_report {
    my ($report) = @_;

    my $dataset = $report->{dataset};

    return join q{},
      'performance_seed status=', $report->{status},              "\n",
      'profile=',                 $report->{profile},             "\n",
      'users=',                   $dataset->{users},              q{ },
      'categories=',              $dataset->{categories},         q{ },
      'threads=',                 $dataset->{threads},            q{ },
      'posts=',                   $dataset->{posts},              q{ },
      'sessions=',                $dataset->{sessions},           q{ },
      'read_states=',             $dataset->{read_states},        q{ },
      'notifications=',           $dataset->{notifications},      q{ },
      'bookmarks=',               $dataset->{bookmarks},          q{ },
      'subscriptions=',           $dataset->{subscriptions},      q{ },
      'reports=',                 $dataset->{reports},            q{ },
      'moderation_actions=',      $dataset->{moderation_actions}, "\n",
      'category_route=',          $report->{routes}{category}, "\n",
      'thread_route=',            $report->{routes}{thread},   "\n",
      'search_route=',            $report->{routes}{search},   "\n";
}

sub _print_usage {
    print _usage(), "\n" or croak 'failed to write usage';

    return 0;
}

sub _usage {
    return
'Usage: script/seed-performance-data [--dry-run] [--json] [--profile small|medium|hot-thread] [--users N] [--categories N] [--threads N] [--posts-per-thread N]';
}

sub _seed_error {
    my ($error) = @_;

    return
        'script/seed-performance-data: PostgreSQL seed failed. '
      . 'Ensure DBD::Pg is installed with script/bootstrap-deps --postgres, '
      . 'the database is reachable, and migrations are applied. Error: '
      . $error;
}

sub _positive_integer {
    my ($value) = @_;

    croak _usage()
      if !defined $value || $value !~ /\A [1-9][[:digit:]]* \z/msx;

    return int $value;
}

sub _uuid {
    my ( $family, $number ) = @_;

    return sprintf '018f%04x-%04x-7000-8000-%012x',
      $family, $number % 65_536, $number;
}

sub _category_id {
    my ($number) = @_;

    return _uuid( $FAMILY_CATEGORY, $number );
}

sub _role_id {
    my ($number) = @_;

    return _uuid( $FAMILY_ROLE, $number );
}

sub _permission_id {
    my ($number) = @_;

    return _uuid( $FAMILY_PERMISSION, $number );
}

sub _thread_id {
    my ($number) = @_;

    return _uuid( $FAMILY_THREAD, $number );
}

sub _user_id {
    my ($number) = @_;

    return _uuid( $FAMILY_USER, $number );
}

sub _role_number_for_user {
    my ($user_number) = @_;

    return 1 if $user_number == 1;
    return 2 if $user_number == 2;

    return 3;
}

sub _profile {
    my ($value) = @_;

    croak _usage()
      if !defined $value
      || ( $value ne $PROFILE_SMALL
        && $value ne $PROFILE_MEDIUM
        && $value ne $PROFILE_HOT_THREAD );

    return $value;
}

sub _apply_profile {
    my ($options) = @_;

    return if $options->{profile} eq 'custom';
    return if $options->{profile} eq $PROFILE_SMALL;

    if ( $options->{profile} eq $PROFILE_MEDIUM ) {
        $options->{users}            = 25;
        $options->{categories}       = 8;
        $options->{threads}          = 120;
        $options->{posts_per_thread} = 15;
        return;
    }

    if ( $options->{profile} eq $PROFILE_HOT_THREAD ) {
        $options->{users}            = 10;
        $options->{categories}       = 3;
        $options->{threads}          = 30;
        $options->{posts_per_thread} = 120;
        return;
    }

    return;
}

sub _category_number {
    my ( $plan, $number ) = @_;

    return ( ( $number - 1 ) % $plan->{dataset}{categories} ) + 1;
}

sub _user_number {
    my ( $plan, $number ) = @_;

    return ( ( $number - 1 ) % $plan->{dataset}{users} ) + 1;
}

sub _thread_number {
    my ( $plan, $number ) = @_;

    return ( ( $number - 1 ) % $plan->{dataset}{threads} ) + 1;
}

sub _post_key {
    my ( undef, $thread_number, $position ) = @_;

    return $thread_number * 10_000 + $position;
}

sub _threads_in_category {
    my ( $plan, $category_number ) = @_;

    my $threads = 0;
    for my $thread_number ( 1 .. $plan->{dataset}{threads} ) {
        $threads++
          if _category_number( $plan, $thread_number ) == $category_number;
    }

    return $threads;
}

sub _post_body {
    my ( $thread_number, $position ) = @_;

    return
        'Performance post '
      . $position
      . ' in thread '
      . $thread_number
      . ' for repeatable GPForum profiling.';
}

sub _timestamp {
    my ($minutes) = @_;

    my $time = DateTime->new(
        year      => 2026,
        month     => 5,
        day       => 24,
        hour      => 8,
        minute    => 0,
        second    => 0,
        time_zone => 'UTC',
    );
    $time->add( minutes => $minutes );

    return $time->strftime('%Y-%m-%d %H:%M:%S+00');
}

sub _minimum {
    my ( $left, $right ) = @_;

    return $left < $right ? $left : $right;
}

1;
