# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Schema;
use GPForum::Service::Community::BookmarkStore;
use GPForum::Service::Community::FeedReader;
use GPForum::Service::Community::MentionReader;
use GPForum::Service::Forum::Readability;
use GPForum::Service::Forum::Viewer;
use GPForum::Service::Notification::Dispatcher;

our $VERSION = '0.001';

# ADR 0102: the lists that point at posts and threads -- the notification
# inbox and its unread count, mentions, bookmarks and the personal feed --
# filter on what the reader can read, in the query, before LIMIT. The SQL is
# generated without a database: DBIx::Class knows the dialect from the DSN.
my $schema =
  GPForum::Schema->connect('dbi:Pg:dbname=gpforum_unused;host=127.0.0.1');
my $user   = '018f1002-0001-7000-8000-000000000001';
my $viewer = GPForum::Service::Forum::Viewer->new(
    member       => 1,
    user_id      => $user,
    category_ids => ['018f1001-0001-7000-8000-000000000009'],
);
my %options = ( limit => 5, viewer => $viewer );

my %list = (
    bookmarks => sub {
        return GPForum::Service::Community::BookmarkStore->new(
            schema => $schema,
            @_
        )->bookmarks_resultset( $user, {%options} );
    },
    feed => sub {
        return GPForum::Service::Community::FeedReader->new(
            schema => $schema,
            @_
        )->feed_resultset( $user, {%options} );
    },
    inbox => sub {
        return GPForum::Service::Notification::Dispatcher->new(
            schema => $schema,
            @_
        )->inbox_resultset( $user, {%options} );
    },
    mentions => sub {
        return GPForum::Service::Community::MentionReader->new(
            schema => $schema,
            @_
        )->mentions_resultset( $user, {%options} );
    },
    unread => sub {
        return GPForum::Service::Notification::Dispatcher->new(
            schema => $schema,
            @_
        )->unread_resultset( $user, $viewer );
    },
);

my $readability =
  GPForum::Service::Forum::Readability->new( schema => $schema );
for my $name ( sort keys %list ) {
    my $filtered = _sql( $list{$name}->( readability => $readability ) );
    ok( _has( $filtered, 'IN ( SELECT readable_post.post_id FROM posts' ),
        "$name: keeps only posts the reader can read" );
    ok(
        _has( $filtered, 'IN ( SELECT readable_thread.thread_id FROM threads' ),
        "$name: and threads"
    );
    like( $filtered, qr/space[.]visibility/msx,
        "$name: judged down to the space" );
    like(
        $filtered,
        qr/readable_thread[.]thread_id [ ] = [ ] (?:me|notification)[.]/msx,
        "$name: one primary-key lookup per row, not a scan of every thread"
    );
    like(
        $filtered,
        qr/_type [ ] = [ ] [?] [ ] AND [ ] [^(]* IN [ ] [(] [ ] SELECT/msx,
        "$name: the type test comes before the lookup it guards"
    );

    # Without readability the list is unfiltered, but still valid SQL: an
    # empty -and left "WHERE ( ( AND user_id = ? ) )", a syntax error.
    my $plain = _sql( $list{$name}->() );
    unlike(
        $plain,
        qr/[(] \s* AND \b/msx,
        "$name: without readability, no dangling AND"
    );
    unlike( $plain, qr/FROM [ ] posts/msx, "$name: and no filter" );
}

like(
    _sql( $list{unread}->( readability => $readability ) ),
    qr/LIMIT [ ] [?]/msx,
    'the unread count stops at its cap ("more than 99")'
);

done_testing();

sub _has {
    my ( $sql, $fragment ) = @_;

    return index( $sql, $fragment ) >= 0;
}

sub _sql {
    my ($resultset) = @_;

    return ${ $resultset->as_query }->[0];
}

1;
