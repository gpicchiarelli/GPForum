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

    _insert_space($dbh);
    _insert_users( $dbh, $plan );
    _insert_sessions( $dbh, $plan );
    _insert_categories( $dbh, $plan );
    _insert_threads_and_posts( $dbh, $plan );
    _insert_category_stats( $dbh, $plan );
    _insert_read_state( $dbh, $plan );
    _insert_notifications( $dbh, $plan );
    _insert_feed_items( $dbh, $plan );

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
                (search_document_id, entity_type, entity_id, space_id,
                 visibility, permission_scope, visibility_version,
                 permission_version, language, title, body, search_vector,
                 source_version, indexed_at)
            VALUES (?, 'thread', ?, ?, 'public', 'public', 1, 1, 'simple',
                    ?, ?, to_tsvector('simple', ?), ?, ?)
            ON CONFLICT (entity_type, entity_id) DO UPDATE SET
                title = EXCLUDED.title,
                body = EXCLUDED.body,
                search_vector = EXCLUDED.search_vector,
                indexed_at = EXCLUDED.indexed_at
        },
        undef,
        _uuid( $FAMILY_SEARCH, $thread_number ),
        _thread_id($thread_number),
        $SPACE_ID,
        $title,
        $body,
        $title . q{ } . $body,
        $SEARCH_DOCUMENT_VERSION,
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

sub _assert_migrated {
    my ($dbh) = @_;

    for my $table (qw(users categories threads posts thread_read_state)) {
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

    return {
        status  => $options->{dry_run} ? 'dry-run' : 'seeded',
        dataset => {
            users            => $users,
            categories       => $categories,
            threads          => $threads,
            posts_per_thread => $posts_per_thread,
            posts            => $posts,
            sessions         => $users,
            read_states      => $users * _minimum( $threads, 3 ),
            notifications    => $notifications,
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
        format           => 'text',
        dry_run          => 0,
        help             => 0,
    };

    while (@arguments) {
        _consume_option( $options, \@arguments );
    }

    return $options;
}

sub _consume_option {
    my ( $options, $arguments ) = @_;

    my $argument = shift @{$arguments};
    my %handler  = (
        '--dry-run' => sub { $options->{dry_run} = 1; },
        '--json'    => sub { $options->{format}  = 'json'; },
        '--help'    => sub { $options->{help}    = 1; },
        '--users'   => sub {
            $options->{users} = _positive_integer( shift @{$arguments} );
        },
        '--categories' => sub {
            $options->{categories} =
              _positive_integer( shift @{$arguments} );
        },
        '--threads' => sub {
            $options->{threads} = _positive_integer( shift @{$arguments} );
        },
        '--posts-per-thread' => sub {
            $options->{posts_per_thread} =
              _positive_integer( shift @{$arguments} );
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
      'performance_seed status=', $report->{status},         "\n",
      'users=',                   $dataset->{users},         q{ },
      'categories=',              $dataset->{categories},    q{ },
      'threads=',                 $dataset->{threads},       q{ },
      'posts=',                   $dataset->{posts},         q{ },
      'sessions=',                $dataset->{sessions},      q{ },
      'read_states=',             $dataset->{read_states},   q{ },
      'notifications=',           $dataset->{notifications}, "\n",
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
'Usage: script/seed-performance-data [--dry-run] [--json] [--users N] [--categories N] [--threads N] [--posts-per-thread N]';
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

sub _thread_id {
    my ($number) = @_;

    return _uuid( $FAMILY_THREAD, $number );
}

sub _user_id {
    my ($number) = @_;

    return _uuid( $FAMILY_USER, $number );
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
    my ( $plan, $thread_number, $position ) = @_;

    return ( $thread_number - 1 ) * $plan->{dataset}{posts_per_thread} +
      $position;
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
