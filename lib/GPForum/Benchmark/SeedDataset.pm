# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Benchmark::SeedDataset;

use v5.40;

use Const::Fast;
use DateTime;
use Digest::SHA   qw(sha256_hex);
use Exporter      qw(import);
use JSON::MaybeXS qw(encode_json);
use List::Util    qw(min pairkeys pairvalues);

our $VERSION = '0.001';

our @EXPORT_OK = qw(dataset_counts insert_dataset seed_id);

# Each kind of row's id family: a seeded id is 018f<family>-..., so a re-seed
# finds its own rows by prefix and leaves every other row alone.
const my %FAMILY => (
    space             => 0x1000,
    category          => 0x1001,
    user              => 0x1002,
    session           => 0x1003,
    thread            => 0x1004,
    post              => 0x1005,
    body              => 0x1006,
    revision          => 0x1007,
    search            => 0x1008,
    notification      => 0x1009,
    role              => 0x100a,
    permission        => 0x100b,
    role_binding      => 0x100c,
    bookmark          => 0x100d,
    subscription      => 0x100e,
    report            => 0x100f,
    moderation_action => 0x1010,
);
const my $MEMBER_ROLE             => 3;
const my $NOTIFICATIONS_PER_USER  => 3;
const my $READ_THREADS            => 3;
const my $READ_POSITION           => 4;
const my $MODERATORS              => 2;
const my $ID_NUMBER_SPAN          => 65_536;
const my $POSTS_PER_THREAD_SPAN   => 10_000;
const my $TRUST_LEVELS            => 4;
const my $SEARCH_DOCUMENT_VERSION => 1;
const my $THREAD_VERSION          => 1;
const my $SPACE_ID                => seed_id( space => 1 );

# When each kind of row was written, in minutes after the seed's epoch; most
# add their own number, so no two are written at the same minute.
const my %MINUTE => (
    session_seen    => 20,
    session_expiry  => 2_000,
    thread_created  => 10,
    thread_activity => 100,
    indexed         => 200,
    stats           => 300,
    read            => 400,
    bookmark        => 450,
    subscription    => 470,
    notification    => 500,
    feed            => 600,
    report          => 700,
    moderation      => 730,
);
const my $PASSWORD_HASH =>
  q{$argon2id$v=19$m=65536,t=3,p=1$gpforum$performance-seed};

const my @ROLES => (
    [ 1, 'administrator', 'Performance administrator' ],
    [ 2, 'moderator',     'Performance moderator' ],
    [ 3, 'member',        'Performance member' ],
);
const my @PERMISSIONS => (
    [ 1, 'admin.view',        'admin',      'view' ],
    [ 2, 'role.manage',       'role',       'manage' ],
    [ 3, 'moderation.view',   'moderation', 'view' ],
    [ 4, 'moderation.action', 'moderation', 'action' ],
    [ 5, 'forum.write',       'forum',      'write' ],
    [ 6, 'report.create',     'report',     'create' ],
);

# [ role, permission ]: the administrator holds every permission, the
# moderator moderates and reports, a member writes and reports.
const my @GRANTS => (
    [ 1, 1 ], [ 1, 2 ], [ 1, 3 ], [ 1, 4 ], [ 1, 5 ], [ 1, 6 ],
    [ 2, 3 ], [ 2, 4 ], [ 2, 6 ], [ 3, 5 ], [ 3, 6 ],
);

# What a re-seed deletes first, children before parents: each table's rows
# whose [ column, id family ] is the seed's, or -- a table alone -- the rows
# of the seed's space.
const my @CLEARED => (
    [
        moderation_actions => [ moderation_action_id => 'moderation_action' ]
    ],
    [ reports            => [ report_id       => 'report' ] ],
    [ notification_inbox => [ notification_id => 'notification' ] ],
    [ notifications      => [ notification_id => 'notification' ] ],
    [
        user_feed_items => [ user_id => 'user' ],
        [ item_id => 'thread' ]
    ],
    [ subscriptions => [ subscription_id => 'subscription' ] ],
    [ bookmarks     => [ bookmark_id     => 'bookmark' ] ],
    [
        user_read_marker_deltas => [ user_id => 'user' ],
        [ thread_id => 'thread' ]
    ],
    [
        thread_read_state => [ user_id => 'user' ],
        [ thread_id => 'thread' ]
    ],
    [ thread_counters => [ thread_id => 'thread' ] ],
    ['search_documents'],
    [ post_revisions => [ revision_id => 'revision' ] ],
    [ post_bodies    => [ body_id     => 'body' ] ],
    [ posts          => [ post_id     => 'post' ] ],
    [ threads        => [ thread_id   => 'thread' ] ],
    [ category_stats => [ category_id => 'category' ] ],
    ['categories'],
    [ role_bindings => [ binding_id => 'role_binding' ] ],
    [ sessions      => [ session_id => 'session' ] ],
    [ users         => [ id         => 'user' ] ],
    ['spaces'],
);

# Each table the seed writes: the key a row written before meets, and the
# columns that row has refreshed -- none keeps it as it is.
const my %CONFLICT => (
    spaces      => [ ['space_id'],      [qw(title description updated_at)] ],
    users       => [ ['id'],            [qw(display_name status updated_at)] ],
    roles       => [ ['role_id'],       [qw(name description)] ],
    permissions => [ ['permission_id'], [qw(name resource_type action)] ],
    role_permissions => [ [qw(role_id permission_id)], [] ],
    role_bindings    => [ ['binding_id'],  [qw(role_id revoked_at)] ],
    sessions         => [ ['session_id'],  [qw(last_seen_at expires_at)] ],
    categories       => [ ['category_id'], [qw(title description updated_at)] ],
    threads     => [ ['thread_id'], [qw(title last_activity_at updated_at)] ],
    posts       => [ ['post_id'],   ['updated_at'] ],
    post_bodies =>
      [ ['body_id'], [qw(body_source body_rendered_safe source_hash)] ],
    post_revisions  => [ ['revision_id'], ['edit_reason'] ],
    thread_counters => [
        ['thread_id'],
        [
            qw(reply_count visible_reply_count last_post_id last_activity_at
              reconciled_at)
        ]
    ],
    search_documents => [
        [qw(entity_type entity_id)],
        [
            qw(category_id author_user_id title body search_vector
              source_created_at indexed_at)
        ]
    ],
    category_stats => [
        ['category_id'],
        [qw(thread_count visible_thread_count post_count reconciled_at)]
    ],
    thread_read_state =>
      [ [qw(user_id thread_id)], [qw(last_read_position last_read_at)] ],
    user_read_marker_deltas =>
      [ [qw(user_id thread_id)], [qw(last_read_position last_read_at)] ],
    bookmarks => [ [qw(user_id target_type target_id)], [qw(note deleted_at)] ],
    subscriptions =>
      [ [qw(user_id target_type target_id)], [qw(preference revoked_at)] ],
    notifications      => [ [qw(notification_id created_at)], ['payload'] ],
    notification_inbox =>
      [ [qw(recipient_user_id notification_id)], ['rank_score'] ],
    user_feed_items =>
      [ [qw(user_id item_type item_id)], [qw(rank_score created_at)] ],
    reports            => [ ['report_id'],            [qw(status details)] ],
    moderation_actions => [ ['moderation_action_id'], [qw(reason metadata)] ],
);

# The values SQL converts on the way in.
const my %PLACEHOLDER => (
    metadata      => '?::jsonb',
    payload       => '?::jsonb',
    search_vector => q{to_tsvector('simple', ?)},
);

# How many rows of each kind a seed of these numbers writes.
sub dataset_counts ($numbers) {
    my ( $users, $threads ) = @{$numbers}{qw(users threads)};

    return {
        users              => $users,
        categories         => $numbers->{categories},
        threads            => $threads,
        posts_per_thread   => $numbers->{posts_per_thread},
        posts              => $threads * $numbers->{posts_per_thread},
        sessions           => $users,
        roles              => scalar @ROLES,
        permissions        => scalar @PERMISSIONS,
        role_bindings      => $users,
        read_states        => $users * min( $threads, $READ_THREADS ),
        bookmarks          => $users,
        subscriptions      => $users,
        notifications      => $users * $NOTIFICATIONS_PER_USER,
        feed_items         => $threads,
        reports            => min( $threads, $users * 2 ),
        moderation_actions => min( $threads, $users ),
    };
}

# Children before parents, so a re-seed starts from nothing of its own.
sub insert_dataset ( $dbh, $plan ) {
    my $dataset = $plan->{dataset};
    _clear_performance_dataset($dbh);

    _upsert( $dbh, spaces      => _space() );
    _upsert( $dbh, users       => map { _user($_) } 1 .. $dataset->{users} );
    _upsert( $dbh, roles       => map { _role( @{$_} ) } @ROLES );
    _upsert( $dbh, permissions => map { _permission( @{$_} ) } @PERMISSIONS );
    _upsert( $dbh, role_permissions => map { _grant( @{$_} ) } @GRANTS );
    _upsert( $dbh,
        role_bindings => map { _role_binding($_) } 1 .. $dataset->{users} );
    _upsert( $dbh, sessions => map { _session($_) } 1 .. $dataset->{users} );
    _upsert( $dbh,
        categories => map { _category($_) } 1 .. $dataset->{categories} );

    for my $thread_number ( 1 .. $dataset->{threads} ) {
        _upsert( $dbh, threads => _thread( $plan, $thread_number ) );
        for my $position ( 1 .. $dataset->{posts_per_thread} ) {
            _insert_post( $dbh, $plan, $thread_number, $position );
        }
        _upsert( $dbh,
            thread_counters => _thread_counter( $plan, $thread_number ) );
        _upsert( $dbh,
            search_documents => _search_document( $plan, $thread_number ) );
    }
    _upsert( $dbh,
        category_stats => map { _category_stats( $plan, $_ ) }
          1 .. $dataset->{categories} );
    _insert_read_state( $dbh, $plan );
    _upsert( $dbh,
        bookmarks => map { _bookmark( $plan, $_ ) }
          1 .. $dataset->{bookmarks} );
    _upsert( $dbh,
        subscriptions => map { _subscription( $plan, $_ ) }
          1 .. $dataset->{subscriptions} );
    for my $number ( 1 .. $dataset->{notifications} ) {
        my $notification = _notification( $plan, $number );
        _upsert( $dbh, notifications => $notification );
        _upsert( $dbh,
            notification_inbox => _inbox_entry( $notification, $number ) );
    }
    _upsert( $dbh,
        user_feed_items => map { _feed_item( $plan, $_ ) }
          1 .. $dataset->{threads} );
    _upsert( $dbh,
        reports => map { _report( $plan, $_ ) } 1 .. $dataset->{reports} );
    _upsert( $dbh,
        moderation_actions => map { _moderation_action( $plan, $_ ) }
          1 .. $dataset->{moderation_actions} );

    return;
}

# The seed's own rows: those whose id carries one of its families, or that
# belong to its space.
sub _clear_performance_dataset ($dbh) {
    for my $cleared (@CLEARED) {
        my ( $table, @families ) = @{$cleared};
        if ( !@families ) {
            $dbh->do( "DELETE FROM $table WHERE space_id = ?",
                undef, $SPACE_ID );
            next;
        }
        my $where = join ' OR ', map {
            sprintf q{%s::text LIKE '018f%04x-%%'}, $_->[0], $FAMILY{ $_->[1] }
        } @families;
        $dbh->do( "DELETE FROM $table WHERE $where", undef );
    }

    return;
}

# Writes rows into a table, each its [ column => value ] pairs in the order
# they are bound. A row the seed wrote before is refreshed as %CONFLICT says.
sub _upsert ( $dbh, $table, @rows ) {
    return if !@rows;

    my ( $key, $refresh ) = @{ $CONFLICT{$table} };
    my @columns = pairkeys @{ $rows[0] };
    my $sql =
      sprintf 'INSERT INTO %s (%s) VALUES (%s) ON CONFLICT (%s) %s',
      $table, join( q{, }, @columns ),
      join( q{, },
        map { exists $PLACEHOLDER{$_} ? $PLACEHOLDER{$_} : q{?} } @columns ),
      join( q{, }, @{$key} ),
      @{$refresh}
      ? 'DO UPDATE SET ' . join( q{, }, map { "$_ = EXCLUDED.$_" } @{$refresh} )
      : 'DO NOTHING';
    for my $row (@rows) {
        $dbh->do( $sql, undef, pairvalues @{$row} );
    }

    return;
}

sub _space {
    return [
        space_id    => $SPACE_ID,
        slug        => 'performance',
        title       => 'Performance Lab',
        description => 'Deterministic performance benchmark space',
        visibility  => 'public',
        position    => 1,
        created_at  => _timestamp(0),
        updated_at  => _timestamp(0),
    ];
}

sub _user ($number) {
    return [
        id                => seed_id( user => $number ),
        username          => 'perf_user_' . $number,
        display_name      => 'Performance User ' . $number,
        email_normalized  => 'perf_user_' . $number . '@example.invalid',
        password_hash     => $PASSWORD_HASH,
        status            => 'active',
        trust_level       => $number % $TRUST_LEVELS,
        email_verified_at => _timestamp($number),
        created_at        => _timestamp($number),
        updated_at        => _timestamp($number),
    ];
}

sub _role ( $number, $name, $description ) {
    return [
        role_id     => seed_id( role => $number ),
        name        => $name,
        description => $description,
        created_at  => _timestamp(0),
    ];
}

sub _permission ( $number, $name, $resource_type, $action ) {
    return [
        permission_id => seed_id( permission => $number ),
        name          => $name,
        resource_type => $resource_type,
        action        => $action,
        created_at    => _timestamp(0),
    ];
}

sub _grant ( $role, $permission ) {
    return [
        role_id       => seed_id( role       => $role ),
        permission_id => seed_id( permission => $permission ),
        created_at    => _timestamp(0),
    ];
}

# The first user administers, the second moderates, the rest are members:
# roles 1, 2 and 3.
sub _role_binding ($user_number) {
    return [
        binding_id => seed_id( role_binding => $user_number ),
        user_id    => seed_id( user         => $user_number ),
        role_id    => seed_id( role => min( $user_number, $MEMBER_ROLE ) ),
        resource_type      => 'space',
        resource_id        => undef,
        space_id           => $SPACE_ID,
        created_by_user_id => seed_id( user => 1 ),
        created_at         => _timestamp($user_number),
        revoked_at         => undef,
    ];
}

sub _session ($number) {
    return [
        session_id      => seed_id( session => $number ),
        user_id         => seed_id( user    => $number ),
        session_hash    => 'performance-session-hash-' . $number,
        created_at      => _timestamp($number),
        last_seen_at    => _at( session_seen   => $number ),
        expires_at      => _at( session_expiry => $number ),
        ip_hash         => 'ip-hash-' . $number,
        user_agent_hash => 'ua-hash-' . $number,
    ];
}

sub _category ($number) {
    return [
        category_id => seed_id( category => $number ),
        space_id    => $SPACE_ID,
        slug        => 'performance-' . $number,
        title       => 'Performance Category ' . $number,
        description => 'Benchmark category ' . $number,
        visibility  => 'public',
        position    => $number,
        created_at  => _timestamp($number),
        updated_at  => _timestamp($number),
    ];
}

sub _thread ( $plan, $thread_number ) {
    return [
        thread_id   => seed_id( thread => $thread_number ),
        category_id =>
          seed_id( category => _category_number( $plan, $thread_number ) ),
        author_user_id =>
          seed_id( user => _user_number( $plan, $thread_number ) ),
        title            => 'Performance thread ' . $thread_number,
        slug             => 'performance-thread-' . $thread_number,
        pinned           => 'false',
        visibility       => 'public',
        moderation_state => 'visible',
        last_activity_at => _at( thread_activity => $thread_number ),
        created_at       => _at( thread_created  => $thread_number ),
        updated_at       => _at( thread_activity => $thread_number ),
    ];
}

# A post, its body and its first revision, then the post pointed at both.
sub _insert_post ( $dbh, $plan, $thread_number, $position ) {
    my $post_key    = _post_key( $plan, $thread_number, $position );
    my $post_id     = seed_id( post     => $post_key );
    my $body_id     = seed_id( body     => $post_key );
    my $revision_id = seed_id( revision => $post_key );
    my $body =
        "Performance post $position in thread $thread_number"
      . q{ for repeatable GPForum profiling.};
    my $created = _timestamp( $thread_number + $position );

    _upsert(
        $dbh,
        posts => [
            post_id        => $post_id,
            thread_id      => seed_id( thread => $thread_number ),
            author_user_id =>
              seed_id( user => _user_number( $plan, $position ) ),
            position         => $position,
            visibility       => 'public',
            moderation_state => 'visible',
            created_at       => $created,
            updated_at       => $created,
        ]
    );
    _upsert(
        $dbh,
        post_bodies => [
            body_id            => $body_id,
            post_id            => $post_id,
            body_format        => 'markdown',
            body_source        => $body,
            body_rendered_safe => '<p>' . $body . '</p>',
            source_hash        => sha256_hex($body),
            created_at         => _timestamp($position),
        ]
    );
    _upsert(
        $dbh,
        post_revisions => [
            revision_id     => $revision_id,
            post_id         => $post_id,
            body_id         => $body_id,
            editor_user_id  => seed_id( user => _user_number( $plan, 1 ) ),
            revision_number => 1,
            edit_reason     => 'performance seed',
            created_at      => _timestamp(1),
        ]
    );
    $dbh->do(
        join( q{ },
            'UPDATE posts SET current_body_id = ?, current_revision_id = ?',
            'WHERE post_id = ?' ),
        undef, $body_id,
        $revision_id,
        $post_id,
    );

    return;
}

sub _thread_counter ( $plan, $thread_number ) {
    my $last_position = $plan->{dataset}{posts_per_thread};
    my $reply_count   = $last_position - 1;

    return [
        thread_id           => seed_id( thread => $thread_number ),
        reply_count         => $reply_count,
        visible_reply_count => $reply_count,
        last_post_id        =>
          seed_id( post => _post_key( $plan, $thread_number, $last_position ) ),
        last_activity_at => _at( thread_activity => $thread_number ),
        reconciled_at    => _at( thread_activity => $thread_number ),
    ];
}

sub _search_document ( $plan, $thread_number ) {
    my $title = 'Performance thread ' . $thread_number;
    my $body  = 'Searchable performance baseline content for GPForum thread '
      . $thread_number;

    return [
        search_document_id => seed_id( search => $thread_number ),
        entity_type        => 'thread',
        entity_id          => seed_id( thread => $thread_number ),
        category_id        =>
          seed_id( category => _category_number( $plan, $thread_number ) ),
        author_user_id =>
          seed_id( user => _user_number( $plan, $thread_number ) ),
        space_id           => $SPACE_ID,
        visibility         => 'public',
        permission_scope   => 'public',
        visibility_version => 1,
        permission_version => 1,
        language           => 'simple',
        title              => $title,
        body               => $body,
        search_vector      => $title . q{ } . $body,
        source_version     => $SEARCH_DOCUMENT_VERSION,
        source_created_at  => _at( thread_activity => $thread_number ),
        indexed_at         => _at( indexed         => $thread_number ),
    ];
}

sub _category_stats ( $plan, $number ) {
    my $threads = grep { _category_number( $plan, $_ ) == $number }
      1 .. $plan->{dataset}{threads};

    return [
        category_id          => seed_id( category => $number ),
        thread_count         => $threads,
        visible_thread_count => $threads,
        post_count           => $threads * $plan->{dataset}{posts_per_thread},
        reconciled_at        => _at('stats'),
    ];
}

# Each user has read the first three threads to their fourth post, in both
# the read state and the marker deltas it is folded from.
sub _insert_read_state ( $dbh, $plan ) {
    my $threads  = min( $plan->{dataset}{threads},          $READ_THREADS );
    my $position = min( $plan->{dataset}{posts_per_thread}, $READ_POSITION );
    for my $user_number ( 1 .. $plan->{dataset}{users} ) {
        for my $thread_number ( 1 .. $threads ) {
            my @read = (
                user_id            => seed_id( user   => $user_number ),
                thread_id          => seed_id( thread => $thread_number ),
                last_read_position => $position,
                last_read_at       => _at('read'),
            );
            _upsert( $dbh, thread_read_state       => [@read] );
            _upsert( $dbh, user_read_marker_deltas => [@read] );
        }
    }

    return;
}

sub _bookmark ( $plan, $number ) {
    return [
        bookmark_id => seed_id( bookmark => $number ),
        user_id     => seed_id( user     => _user_number( $plan, $number ) ),
        target_type => 'thread',
        target_id   => seed_id( thread => _thread_number( $plan, $number ) ),
        note        => 'benchmark bookmark ' . $number,
        created_at  => _at( bookmark => $number ),
        deleted_at  => undef,
    ];
}

sub _subscription ( $plan, $number ) {
    return [
        subscription_id => seed_id( subscription => $number ),
        user_id         => seed_id( user => _user_number( $plan, $number ) ),
        target_type => 'thread',
        target_id   => seed_id( thread => _thread_number( $plan, $number ) ),
        preference  => 'all',
        created_at  => _at( subscription => $number ),
        revoked_at  => undef,
    ];
}

sub _notification ( $plan, $number ) {
    my $thread_id = seed_id( thread => _thread_number( $plan, $number ) );

    return [
        notification_id   => seed_id( notification => $number ),
        recipient_user_id => seed_id( user => _user_number( $plan, $number ) ),
        source_type       => 'thread',
        source_id         => $thread_id,
        notification_type => 'reply_created',
        payload           => encode_json( { thread_id => $thread_id } ),
        created_at        => _at( notification => $number ),
    ];
}

sub _inbox_entry ( $notification, $number ) {
    my %notification = @{$notification};

    return [
        recipient_user_id => $notification{recipient_user_id},
        notification_id   => $notification{notification_id},
        created_at        => $notification{created_at},
        rank_score        => $number,
    ];
}

sub _feed_item ( $plan, $thread_number ) {
    return [
        user_id    => seed_id( user => _user_number( $plan, $thread_number ) ),
        item_type  => 'thread',
        item_id    => seed_id( thread => $thread_number ),
        created_at => _at( feed => $thread_number ),
        rank_score => $THREAD_VERSION / $thread_number,
        visibility_version => 1,
        permission_version => 1,
    ];
}

# Odd reports are of a thread, even ones of its first post.
sub _report ( $plan, $number ) {
    my $thread_number = _thread_number( $plan, $number );
    my $target_type   = $number % 2 ? 'thread' : 'post';

    return [
        report_id        => seed_id( report => $number ),
        reporter_user_id => seed_id( user   => _user_number( $plan, $number ) ),
        target_type      => $target_type,
        target_id        => $target_type eq 'thread'
        ? seed_id( thread => $thread_number )
        : seed_id( post   => _post_key( $plan, $thread_number, 1 ) ),
        reason                     => 'spam',
        details                    => 'benchmark report ' . $number,
        status                     => 'open',
        assigned_moderator_user_id =>
          seed_id( user => min( $plan->{dataset}{users}, $MODERATORS ) ),
        created_at => _at( report => $number ),
    ];
}

sub _moderation_action ( $plan, $number ) {
    return [
        moderation_action_id => seed_id( moderation_action => $number ),
        actor_user_id        =>
          seed_id( user => min( $plan->{dataset}{users}, $MODERATORS ) ),
        action_type => 'post.reviewed',
        target_type => 'post',
        target_id   => seed_id(
            post => _post_key( $plan, _thread_number( $plan, $number ), 1 )
        ),
        reason     => 'benchmark moderation action ' . $number,
        metadata   => '{}',
        created_at => _at( moderation => $number ),
    ];
}

sub seed_id ( $kind, $number ) {
    return sprintf '018f%04x-%04x-7000-8000-%012x',
      $FAMILY{$kind}, $number % $ID_NUMBER_SPAN, $number;
}

sub _category_number ( $plan, $number ) {
    return ( ( $number - 1 ) % $plan->{dataset}{categories} ) + 1;
}

sub _user_number ( $plan, $number ) {
    return ( ( $number - 1 ) % $plan->{dataset}{users} ) + 1;
}

sub _thread_number ( $plan, $number ) {
    return ( ( $number - 1 ) % $plan->{dataset}{threads} ) + 1;
}

sub _post_key ( $, $thread_number, $position ) {
    return $thread_number * $POSTS_PER_THREAD_SPAN + $position;
}

sub _at ( $event, $number = 0 ) {
    return _timestamp( $MINUTE{$event} + $number );
}

sub _timestamp ($minutes) {
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

1;

__END__

=head1 NAME

GPForum::Benchmark::SeedDataset - The rows the performance seed writes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use GPForum::Benchmark::SeedDataset qw(insert_dataset seed_id);

    insert_dataset( $dbh, $plan );    # in the caller's transaction
    my $thread_route = '/t/' . seed_id( thread => 1 );

=head1 DESCRIPTION

The deterministic dataset L<GPForum::Command::PerformanceSeed> loads: a
space, its users, roles, permissions and sessions, categories, threads with
their posts, bodies and revisions, the counters and the search projection,
read state, bookmarks, subscriptions, notifications, feed items, reports and
moderation actions. Every id belongs to a family of its kind, so a re-seed
deletes its own rows and only those, and writes each row as an upsert keyed
the way the table is.

=head1 SUBROUTINES/METHODS

=head2 dataset_counts

Given the C<users>, C<categories>, C<threads> and C<posts_per_thread> to
seed, a hash reference of how many rows of each kind the seed writes: the
C<dataset> of a plan.

=head2 insert_dataset

Given a database handle and a plan -- a hash reference whose C<dataset>
holds the C<users>, C<categories>, C<threads>, C<posts_per_thread>,
C<bookmarks>, C<subscriptions>, C<notifications>, C<reports> and
C<moderation_actions> counts -- deletes the rows an earlier seed wrote and
writes the dataset. The caller owns the transaction; constraints are
expected deferred.

=head2 seed_id

Given a kind of row (C<space>, C<category>, C<user>, C<thread>, C<post>,
C<role>, ...) and a number, the deterministic UUID the seed gives it.

=head1 DIAGNOSTICS

DBI's error, as the handle raises it, when a statement fails.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<DateTime>, L<Digest::SHA>, L<Exporter>, L<JSON::MaybeXS>,
L<List::Util>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
