# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use MIME::Base64 qw(encode_base64url);
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Community::MentionStore;
use GPForum::Service::Forum::Viewer;
use GPForum::Service::Forum::ViewerResolver;
use GPForum::Service::Notification::RecipientPolicy;
use GPForum::Service::Operations::DbQueryStats;
use GPForum::Service::Search::PermissionEngine;
use GPForum::Service::Search::Searcher;
use GPForum::Test::PostgresHarness;
use GPForum::Test::RealtimeConnection;

our $VERSION = '0.001';

const my $HTTP_OK        => 200;
const my $HTTP_NOT_FOUND => 404;
const my $CATEGORIES     => 3;

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all =>
      'set GPFORUM_DATABASE_DSN to run the effective visibility test';
}

# ADR 0102 against PostgreSQL and the real application: who reads a private
# category, a members-only category, and a private thread in a public one.
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;
my $database =
  GPForum::Test::PostgresHarness::create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN} = $database->{dsn};
my $prepared = GPForum::Test::PostgresHarness::prepare_database();
is( $prepared->{migrate}, 0, 'migrations apply' );
is( $prepared->{seed},    0, 'the seed loads' );

my $dbh        = GPForum::Test::PostgresHarness::connect_schema()->storage->dbh;
my @categories = @{
    $dbh->selectall_arrayref(
        'SELECT category_id, title, space_id FROM categories'
          . ' WHERE deleted_at IS NULL ORDER BY position LIMIT 3',
        { Slice => {} }
    )
};
cmp_ok( scalar @categories,
    q{>=}, $CATEGORIES, 'the seed has three categories' );
my ( $open, $staff, $club ) = @categories;
$dbh->do( q{UPDATE categories SET visibility = 'private' WHERE category_id = ?},
    undef, $staff->{category_id} );
$dbh->do( q{UPDATE categories SET visibility = 'members' WHERE category_id = ?},
    undef, $club->{category_id} );

my %thread_in = map {
    $_->{category_id} => scalar $dbh->selectrow_array(
        q{SELECT thread_id FROM threads WHERE category_id = ?}
          . q{ AND deleted_at IS NULL AND visibility = 'public'}
          . q{ AND moderation_state = 'visible' LIMIT 1},
        undef, $_->{category_id}
    )
} @categories;
ok( $thread_in{ $staff->{category_id} } && $thread_in{ $club->{category_id} },
    'each restricted category has a thread' );

my @users = @{
    $dbh->selectcol_arrayref(
q{SELECT id FROM users WHERE status = 'active' ORDER BY username LIMIT 4}
    )
};
my ( $author, $member, $granted, $suspended ) = @users;

# A private thread in the open category, by $author.
my ($private_thread) = $dbh->selectrow_array(
q{SELECT thread_id FROM threads WHERE category_id = ? AND author_user_id = ?}
      . q{ AND deleted_at IS NULL AND moderation_state = 'visible' LIMIT 1},
    undef, $open->{category_id}, $author
);
$private_thread //= _thread_by( $author, $open->{category_id} );
$dbh->do( q{UPDATE threads SET visibility = 'private' WHERE thread_id = ?},
    undef, $private_thread );
$dbh->do( q{UPDATE posts SET visibility = 'private' WHERE thread_id = ?},
    undef, $private_thread );

# category.read on the staff category, for $granted.
my ($permission) = $dbh->selectrow_array(
        q{INSERT INTO permissions (permission_id, name, resource_type, action)}
      . q{ VALUES (gen_random_uuid(), 'category.read', 'category', 'read')}
      . q{ RETURNING permission_id} );
my ($role) = $dbh->selectrow_array(
q{INSERT INTO roles (role_id, name) VALUES (gen_random_uuid(), 'staff_reader')}
      . q{ RETURNING role_id} );
$dbh->do(
    q{INSERT INTO role_permissions (role_id, permission_id) VALUES (?, ?)},
    undef, $role, $permission );
$dbh->do(
    q{INSERT INTO role_bindings (binding_id, user_id, role_id, resource_type,}
      . q{ resource_id, space_id) VALUES (gen_random_uuid(), ?, ?, 'category', ?, ?)},
    undef, $granted, $role, $staff->{category_id}, $staff->{space_id}
);
$dbh->do(
    q{INSERT INTO suspensions (suspension_id, user_id, actor_user_id, reason)}
      . q{ VALUES (gen_random_uuid(), ?, ?, 'visibility test')},
    undef, $suspended, $author
);

my $staff_thread = $thread_in{ $staff->{category_id} };
my $club_thread  = $thread_in{ $club->{category_id} };
my %expect       = (
    anonymous => {
        categories_list => [ 0, 0 ],
        pages           => [
            $HTTP_NOT_FOUND, $HTTP_NOT_FOUND, $HTTP_NOT_FOUND,
            $HTTP_NOT_FOUND, $HTTP_NOT_FOUND
        ],
    },
    member => {
        categories_list => [ 0, 1 ],
        pages           => [
            $HTTP_NOT_FOUND, $HTTP_OK, $HTTP_NOT_FOUND,
            $HTTP_OK,        $HTTP_NOT_FOUND
        ]
    },
    author => {
        categories_list => [ 0, 1 ],
        pages           =>
          [ $HTTP_NOT_FOUND, $HTTP_OK, $HTTP_NOT_FOUND, $HTTP_OK, $HTTP_OK ]
    },
    granted => {
        categories_list => [ 1, 1 ],
        pages => [ $HTTP_OK, $HTTP_OK, $HTTP_OK, $HTTP_OK, $HTTP_NOT_FOUND ]
    },
    suspended => {
        categories_list => [ 0, 0 ],
        pages           => [
            $HTTP_NOT_FOUND, $HTTP_NOT_FOUND, $HTTP_NOT_FOUND,
            $HTTP_NOT_FOUND, $HTTP_NOT_FOUND
        ]
    },
);
my %user_for = (
    anonymous => undef,
    author    => $author,
    granted   => $granted,
    member    => $member,
    suspended => $suspended,
);

for my $who (qw(anonymous member author granted suspended)) {
    my $client = Test::Mojo->new('GPForum');
    my $routes = $client->app->routes;
    $routes->get('/__test/session/:user_id')->to(
        cb => sub {
            my ($controller) = @_;
            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( json => { ok => 1 } );
        }
    );
    if ( $user_for{$who} ) {
        $client->get_ok("/__test/session/$user_for{$who}");
    }

    $client->get_ok('/categories');
    my $list = $client->tx->res->body;
    is_deeply(
        [
            map { index( $list, qq{/c/$_} ) >= 0 ? 1 : 0 }
              $staff->{category_id},
            $club->{category_id}
        ],
        $expect{$who}{categories_list},
        "$who: /categories lists the private and members categories as expected"
    );

    my @codes;
    for my $path (
        "/c/$staff->{category_id}", "/c/$club->{category_id}",
        "/t/$staff_thread",         "/t/$club_thread",
        "/t/$private_thread",
      )
    {
        $client->get_ok($path);
        push @codes, $client->tx->res->code;
    }
    is_deeply( \@codes, $expect{$who}{pages},
"$who: private category, members category, their threads, a private thread"
    );
}

# A private reply in a public thread stays private on every page -- the
# review of stage 1 found the second page on dropped the post filter.
my ( $paged_thread, $private_post ) = $dbh->selectrow_array(
q{SELECT p.thread_id, p.post_id FROM posts p JOIN threads t USING (thread_id)}
      . q{ WHERE t.category_id = ? AND t.thread_id <> ? AND p.position > 1}
      . q{ AND p.author_user_id <> ? AND p.deleted_at IS NULL LIMIT 1},
    undef, $open->{category_id}, $private_thread, $member
);
$dbh->do( q{UPDATE posts SET visibility = 'private' WHERE post_id = ?},
    undef, $private_post );
my $cursor       = encode_base64url('0|00000000-0000-0000-0000-000000000000');
my $pager        = Test::Mojo->new('GPForum');
my $pager_routes = $pager->app->routes;
$pager_routes->get('/__test/session/:user_id')->to(
    cb => sub {
        my ($controller) = @_;
        $controller->session( user_id => $controller->param('user_id') );
        return $controller->render( json => { ok => 1 } );
    }
);
$pager->get_ok("/__test/session/$member");
$pager->get_ok("/t/$paged_thread");
$pager->element_exists_not( "#post-$private_post",
    'a member does not see another member\'s private reply on page one' );
$pager->get_ok("/t/$paged_thread?after=$cursor");
$pager->element_exists_not( "#post-$private_post", 'nor on a later page' );

# A member reads a thread in the members-only category, but the page is not
# public: it must not ask to be indexed or carry OpenGraph data.
my $reader        = Test::Mojo->new('GPForum');
my $reader_routes = $reader->app->routes;
$reader_routes->get('/__test/session/:user_id')->to(
    cb => sub {
        my ($controller) = @_;
        $controller->session( user_id => $controller->param('user_id') );
        return $controller->render( json => { ok => 1 } );
    }
);
$reader->get_ok("/__test/session/$member");
$reader->get_ok("/t/$club_thread");
$reader->element_exists('meta[name="robots"][content="noindex,nofollow"]');
$reader->element_exists_not('meta[property="og:title"]');

# A profile is public for everyone: activity in a private category is not
# on it, whoever looks -- the author and a grant holder included.
my ($staff_author) = $dbh->selectrow_array(
    'SELECT u.username FROM threads t JOIN users u ON u.id = t.author_user_id'
      . ' WHERE t.thread_id = ?',
    undef, $staff_thread
);
my $visitor = Test::Mojo->new('GPForum');
$visitor->get_ok("/u/$staff_author");
ok(
    index( $visitor->tx->res->body, "/t/$staff_thread" ) < 0,
    'a thread in a private category is not on its author\'s public profile'
);

# Search judges a document's category and space live (stage 2): a thread in a
# category that turned private leaves search results at once, before any
# reindex.
my $schema   = GPForum::Test::PostgresHarness::connect_schema();
my $searcher = GPForum::Service::Search::Searcher->new(
    permission_engine =>
      GPForum::Service::Search::PermissionEngine->new( schema => $schema ),
    schema => $schema,
);
my $resolver =
  GPForum::Service::Forum::ViewerResolver->new( schema => $schema );
my %search_expect = (
    anonymous => [ 0, 0 ],
    author    => [ 0, 1 ],
    granted   => [ 1, 1 ],
    member    => [ 0, 1 ],
    suspended => [ 0, 0 ],
);
for my $who ( sort keys %search_expect ) {
    my $viewer =
        $user_for{$who}
      ? $resolver->resolve( $user_for{$who} )
      : GPForum::Service::Forum::Viewer->anonymous;
    my %found = map { $_->{entity_id} => 1 } @{
        $searcher->search( { viewer => $viewer },
            'performance', { limit => 50 } )
    };
    is_deeply(
        [ map { $found{$_} ? 1 : 0 } $staff_thread, $club_thread ],
        $search_expect{$who},
"$who: search finds the private and members categories' threads as expected"
    );
}

# Notifications and mentions (stage 3): only recipients who can read the
# source. A reply or mention in the staff category notified every subscriber
# or mentioned user, handing them its thread, post and actor.
my $policy =
  GPForum::Service::Notification::RecipientPolicy->new( schema => $schema );
my %notify_expect = (
    author    => [ 0, 1, 1 ],
    granted   => [ 1, 1, 0 ],
    member    => [ 0, 1, 0 ],
    suspended => [ 0, 0, 0 ],
);
for my $who ( sort keys %notify_expect ) {
    is_deeply(
        [
            map { $policy->can_notify( $user_for{$who}, 'thread', $_ ) ? 1 : 0 }
              $staff_thread,
            $club_thread,
            $private_thread
        ],
        $notify_expect{$who},
        "$who: notified about the staff, club and private threads as expected"
    );
}
ok(
    !$policy->can_notify( $member, 'thread', 'not-a-uuid' ),
    'a source that is not a uuid notifies nobody'
);
ok(
    !$policy->can_notify( $member, 'forum', $staff_thread ),
    'nor one of a kind the policy does not know'
);

my ($staff_post) = $dbh->selectrow_array(
    'SELECT post_id FROM posts WHERE thread_id = ? ORDER BY position LIMIT 1',
    undef, $staff_thread );
my %username = map {
    $_ =>
      scalar $dbh->selectrow_array( 'SELECT username FROM users WHERE id = ?',
        undef, $_ )
} $member, $granted;
my $mentions = GPForum::Service::Community::MentionStore->new(
    readability => $policy,
    schema      => $schema,
)->record_for_source(
    {
        actor_id    => $author,
        body_source => "hello \@$username{$member} and \@$username{$granted}",
        source_id   => $staff_post,
        source_type => 'post',
    }
);
is_deeply( [ map { $_->{reason} } @{ $mentions->{skipped} } ],
    ['source_not_readable'],
    'a mention of someone who cannot read the staff post is not recorded' );
is(
    scalar $dbh->selectrow_array(
'SELECT count(*) FROM mentions WHERE source_id = ? AND mentioned_user_id = ?',
        undef,
        $staff_post,
        $granted
    ),
    1,
    'a mention of a grant holder is'
);

# Attachment downloads (stage 3): a file on a staff post is served only to
# those who can read the post, and to its uploader. The post's own
# visibility (public) used to be enough.
my ($attachment) = $dbh->selectrow_array('SELECT gen_random_uuid()');
$dbh->do(
    q{INSERT INTO attachments (attachment_id, owner_user_id, object_key,}
      . q{ original_filename, media_type, byte_size, checksum, state,}
      . q{ scan_status) VALUES (?, ?, ?, 'plan.txt', 'text/plain', 1, 'x',}
      . q{ 'available', 'clean')},
    undef, $attachment, $author, "visibility/$attachment"
);
$dbh->do(
    q{INSERT INTO attachment_links (attachment_link_id, attachment_id,}
      . q{ target_type, target_id) VALUES (gen_random_uuid(), ?, 'post', ?)},
    undef, $attachment, $staff_post
);
_downloads_as_expected( $attachment, \%user_for );
_lists_as_expected(
    {
        club         => $club_thread,
        staff_post   => $staff_post,
        staff_thread => $staff_thread,
    },
    $member, $granted
);

# The viewer resolution is hand-written SQL: it counts against the request's
# query statistics and the endpoint budgets like any DBIx::Class statement.
my $stats = GPForum::Service::Operations::DbQueryStats->new;
$stats->attach_to_schema($schema);
my $token = $stats->start_request( { route => 'visibility-test' } );
$resolver->resolve($member);
is( $stats->finish_request( $token, {} )->{queries},
    1, 'resolving a viewer is one counted query' );

_creation_inherits( $club->{category_id}, $club_thread, $member );

# A hidden thread is readable by nobody -- and asking must not die: the
# liveness check read a restricted hash with the key 'hidden', which killed
# notifications, downloads and realtime for any hidden thread.
$dbh->do( q{UPDATE threads SET moderation_state = 'hidden' WHERE thread_id = ?},
    undef, $club_thread );
ok( !$policy->can_notify( $member, 'thread', $club_thread ),
    'a hidden thread notifies nobody' );
is_deeply( [ $policy->readers_of( 'thread', $club_thread, $member, $granted ) ],
    [], 'and has no readers' );
$dbh->do(
    q{UPDATE threads SET moderation_state = 'visible' WHERE thread_id = ?},
    undef, $club_thread );
_realtime_as_expected(
    \%user_for,   \%notify_expect, $staff_thread,
    $club_thread, $private_thread
);

$schema->storage->disconnect;
$dbh->disconnect;
GPForum::Test::PostgresHarness::drop_database($database);

done_testing();

# Each reader downloads the staff post's file, through the application's own
# attachment store, as ADR 0102 expects.
sub _downloads_as_expected {
    my ( $file, $user_for ) = @_;

    my $app      = Test::Mojo->new('GPForum')->app;
    my $store    = $app->build_controller->gp_attachment_store;
    my %expected = (
        anonymous => 'forbidden',
        author    => 'ok',
        granted   => 'ok',
        member    => 'forbidden',
        suspended => 'forbidden',
    );
    for my $who ( sort keys %expected ) {
        my $user     = $user_for->{$who};
        my $download = $store->download_for(
            {
                attachment_id  => $file,
                viewer         => $resolver->resolve($user),
                viewer_user_id => $user,
            }
        );
        is( $download->{ok} ? 'ok' : $download->{error},
            $expected{$who},
            "$who: downloads the staff post's file as expected" );
    }

    return;
}

# Lists that point at posts and threads (stage 3): the notification inbox and
# its unread count, mentions, bookmarks and the personal feed keep only what
# the reader can still read. Each row is written as if from before the staff
# category turned private: one about the staff category, one about the club.
sub _lists_as_expected {
    my ( $source, @readers ) = @_;

    my %label_of = (
        $source->{club}         => 'club',
        $source->{staff_post}   => 'staff',
        $source->{staff_thread} => 'staff',
    );
    my %seen = (
        $readers[0] => ['club'],
        $readers[1] => [ 'club', 'staff' ],
    );
    my $app      = Test::Mojo->new('GPForum')->app;
    my $services = $app->build_controller;
    for my $user (@readers) {
        my %notification_of = _point_at_sources( $user, $source );
        my $viewer          = $resolver->resolve($user);
        my $name            = $user eq $readers[0] ? 'member' : 'granted';
        my $dispatcher      = $services->gp_notification_dispatcher;
        my $inbox           = $dispatcher->list_page_for_user( $user,
            { limit => 50, viewer => $viewer } );
        is_deeply(
            [
                sort
                  map { $notification_of{ $_->get_column('notification_id') } }
                  @{ $inbox->{items} }
            ],
            $seen{$user},
            "$name: the inbox shows the notifications as expected"
        );
        is(
            $dispatcher->unread_count_for_user( $user, $viewer ),
            scalar @{ $seen{$user} },
            "$name: and counts them unread"
        );

        my %lists = (
            bookmarks => [
                $services->gp_bookmark_store->list_page_for_user(
                    $user,
                    { limit => 50, target_type => 'thread', viewer => $viewer }
                ),
                'target_id'
            ],
            feed => [
                $services->gp_feed_reader->list_page_for_user(
                    $user, { limit => 50, viewer => $viewer }
                ),
                'item_id'
            ],
            mentions => [
                $services->gp_mention_reader->list_page_for_recipient(
                    $user, { limit => 50, viewer => $viewer }
                ),
                'source_id'
            ],
        );

        for my $list ( sort keys %lists ) {
            my ( $page, $column ) = @{ $lists{$list} };
            is_deeply(
                [
                    sort map { $label_of{ $_->get_column($column) } }
                      @{ $page->{items} }
                ],
                $seen{$user},
                "$name: $list show the rows as expected"
            );
        }
        is(
            $dispatcher->mark_all_read($user)->{marked_count},
            scalar @{ $seen{$user} },
            "$name: marking all read marks only what the inbox shows"
        );
    }
    $services->gp_schema->storage->disconnect;

    return;
}

# One notification, mention, bookmark and feed item about the club thread
# and one about the staff category (its post or its thread), and nothing
# else of the user's. Returns the notifications' labels by id.
sub _point_at_sources {
    my ( $user, $source ) = @_;

    for my $owned (
        [qw(notification_inbox recipient_user_id)],
        [qw(mentions mentioned_user_id)],
        [qw(bookmarks user_id)], [qw(user_feed_items user_id)],
      )
    {
        $dbh->do( "DELETE FROM $owned->[0] WHERE $owned->[1] = ?",
            undef, $user );
    }

    my %about = (
        club  => [ 'thread', $source->{club},       $source->{club} ],
        staff => [ 'post',   $source->{staff_post}, $source->{staff_thread} ],
    );
    my %notification_of;
    for my $label ( sort keys %about ) {
        my ( $type, $id, $thread ) = @{ $about{$label} };
        my ( $notification, $created ) = $dbh->selectrow_array(
            q{INSERT INTO notifications (notification_id, recipient_user_id,}
              . q{ source_type, source_id, notification_type) VALUES}
              . q{ (gen_random_uuid(), ?, ?, ?, 'reply')}
              . q{ RETURNING notification_id, created_at},
            undef, $user, $type, $id
        );
        $notification_of{$notification} = $label;
        $dbh->do(
            q{INSERT INTO notification_inbox (recipient_user_id,}
              . q{ notification_id, created_at) VALUES (?, ?, ?)},
            undef, $user, $notification, $created
        );
        $dbh->do(
            q{INSERT INTO mentions (mention_id, source_type, source_id,}
              . q{ actor_id, mentioned_user_id, mentioned_username)}
              . q{ SELECT gen_random_uuid(), ?, ?, id, id, username}
              . q{ FROM users WHERE id = ?},
            undef, $type, $id, $user
        );
        $dbh->do(
            q{INSERT INTO bookmarks (bookmark_id, user_id, target_type,}
              . q{ target_id) VALUES (gen_random_uuid(), ?, 'thread', ?)},
            undef, $user, $thread
        );
        $dbh->do(
            q{INSERT INTO user_feed_items (user_id, item_type, item_id,}
              . q{ created_at, visibility_version, permission_version)}
              . q{ VALUES (?, 'thread', ?, now(), 1, 1)},
            undef, $user, $thread
        );
    }

    return %notification_of;
}

# The write path (ADR 0102): a thread or reply without a visibility inherits
# the effective visibility of its category or thread, and a broader one is
# refused -- so what members write stays members-only if the category is
# later opened.
sub _creation_inherits {
    my ( $category_id, $thread_id, $user ) = @_;

    my $app      = Test::Mojo->new('GPForum')->app;
    my $services = $app->build_controller;
    my $workflow = $services->gp_posting_workflow;
    my %thread   = (
        author_user_id => $user,
        body_source    => 'Members talk',
        category_id    => $category_id,
        title          => 'A members-only thread',
        viewer         => $resolver->resolve($user),
    );

    my $created =
      $workflow->create_thread( { %thread, command_id => _uuid() } );
    is(
        _stored_visibility(
            'threads', 'thread_id', $created->{stored}{thread}
        ),
        'members',
        'a thread without a visibility inherits its members-only category\'s'
    );
    is(
        $workflow->create_thread(
            { %thread, command_id => _uuid(), visibility => 'public' }
        )->{status},
        'invalid',
        'a public thread in a members-only category is refused'
    );

    my $reply = $workflow->create_reply(
        {
            author_user_id => $user,
            body_source    => 'A reply among members',
            command_id     => _uuid(),
            thread_id      => $thread_id,
            viewer         => $thread{viewer},
        }
    );
    is(
        _stored_visibility( 'posts', 'post_id', $reply->{stored}{post} ),
        'members',
        'a reply to a public thread in a members-only category is members-only'
    );
    $services->gp_schema->storage->disconnect;

    return;
}

sub _stored_visibility {
    my ( $table, $key, $row ) = @_;

    my $id = ref $row eq 'HASH' ? $row->{$key} : $row->get_column($key);
    return
      scalar $dbh->selectrow_array(
        "SELECT visibility FROM $table WHERE $key = ?",
        undef, $id );
}

sub _uuid {
    return scalar $dbh->selectrow_array('SELECT gen_random_uuid()');
}

# Realtime thread channels (stage 3) open to whoever can read the thread, as
# notifications judge it, and every broadcast asks again: once the grant is
# revoked, its holder is sent nothing. Last, because it revokes the grant.
sub _realtime_as_expected {
    my ( $user_for, $expected, @threads ) = @_;

    my $app        = Test::Mojo->new('GPForum')->app;
    my $controller = $app->build_controller;
    my $hub        = $controller->gp_realtime_hub;
    for my $who ( sort keys %{$expected} ) {
        my $actor = { user_id => $user_for->{$who} };
        is_deeply(
            [
                map {
                    $hub->authorizer->authorize( $actor, "thread:$_", {} )->{ok}
                      ? 1
                      : 0
                } @threads
            ],
            $expected->{$who},
"$who: subscribes to the staff, club and private threads as expected"
        );
    }

    my $holder  = { user_id => $user_for->{granted} };
    my $channel = "thread:$threads[0]";
    $hub->register_connection( 'granted', $holder,
        GPForum::Test::RealtimeConnection->new );
    $hub->subscribe(
        { actor => $holder, channel => $channel, connection_id => 'granted' } );
    is( $hub->broadcast( $channel, { type => 'probe' } )->{delivered},
        1, 'a grant holder receives the staff thread\'s activity' );
    $dbh->do( 'DELETE FROM role_bindings WHERE user_id = ?',
        undef, $user_for->{granted} );
    is( $hub->broadcast( $channel, { type => 'probe' } )->{delivered},
        0, 'and once the grant is revoked, no longer' );
    $controller->gp_schema->storage->disconnect;

    return;
}

sub _thread_by {
    my ( $user, $category_id ) = @_;

    my ($thread) = $dbh->selectrow_array(
q{SELECT thread_id FROM threads WHERE category_id = ? AND deleted_at IS NULL}
          . q{ AND moderation_state = 'visible' LIMIT 1},
        undef, $category_id
    );
    $dbh->do( 'UPDATE threads SET author_user_id = ? WHERE thread_id = ?',
        undef, $user, $thread );

    return $thread;
}

1;
