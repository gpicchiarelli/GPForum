# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;
use utf8;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Notification::Renderer;

our $VERSION = '0.001';

# The subscription and preference stores, the dispatcher and the inbox it
# reads run on PostgreSQL, in t/integration/postgres-notifications.t. What
# stays here needs no database: how a notification reads in the inbox and
# in an email.
my $renderer           = GPForum::Service::Notification::Renderer->new;
my $reply_presentation = $renderer->render_inbox_item(
    'it',
    {
        notification_type => 'reply',
        source_type       => 'post',
        source_id         => 'post-1',
        payload           => { thread_id => 'thread-1', post_id => 'post-1' },
    }
);
is(
    $reply_presentation->{title},
    'Nuova risposta in una discussione seguita',
    'reply notification title is localized for inbox rendering'
);
is(
    $reply_presentation->{email}{subject},
    'Nuova risposta in una discussione seguita',
    'reply email subject uses the same localized notification template'
);

my $mention_presentation = $renderer->render_inbox_item(
    'en',
    {
        notification_type => 'mention',
        source_type       => 'post',
        source_id         => 'post-2',
        payload           => { thread_id => 'thread-1', post_id => 'post-2' },
    }
);
is(
    $mention_presentation->{title},
    'You were mentioned',
    'mention notification title is localized'
);
is(
    $mention_presentation->{email}{subject},
    'You were mentioned on GPForum',
    'mention email subject is localized'
);

my $follow_presentation = $renderer->render_inbox_item(
    'it',
    {
        notification_type => 'follow',
        source_type       => 'thread',
        source_id         => 'thread-1',
        payload           => { thread_id => 'thread-1' },
    }
);
is(
    $follow_presentation->{email}{subject},
    'Nuova attività in una discussione seguita',
    'follow email subject is localized'
);

my $fallback_presentation = $renderer->render_inbox_item(
    'zz',
    {
        notification_type => 'unknown',
        source_type       => 'post',
        source_id         => 'post-3',
        payload           => {},
    }
);
is( $fallback_presentation->{title},
    'Notification', 'unsupported locale and type use safe fallback text' );

my $rendered_mention = $renderer->render_mention(
    'it',
    {
        mention_id          => 'mention-1',
        source_type         => 'post',
        source_id           => 'post-1',
        actor_id            => 'user-2',
        actor_username      => 'reply_author',
        actor_profile_label => '@reply_author',
        actor_display_name  => 'Reply Author',
        mentioned_user_id   => 'user-1',
        mentioned_username  => 'giacomo',
    }
);
is( $rendered_mention->{by_label},
    'Menzione da', 'mention list label is localized' );
is(
    $rendered_mention->{email}{subject},
    '@reply_author ti ha menzionato su GPForum',
    'mention-specific email subject includes localized actor context'
);

done_testing();

1;
