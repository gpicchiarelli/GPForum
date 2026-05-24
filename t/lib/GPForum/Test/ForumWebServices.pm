package GPForum::Test::ForumWebServices;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has mode => 'forum';

sub can_participate {
    return { ok => 1 };
}

sub home_page {
    my ($self) = @_;

    return {
        categories     => $self->list_categories,
        latest_threads => {
            items => [
                {
                    thread_id        => 'thread-1',
                    category_id      => 'category-1',
                    author_user_id   => 'user-1',
                    title            => 'Welcome',
                    slug             => 'welcome',
                    visibility       => 'public',
                    moderation_state => 'visible',
                    last_activity_at => '2026-05-23T12:00:00Z',
                    safe_excerpt     => 'First public post',
                },
            ],
            next_cursor => 'home-thread-cursor',
        },
    };
}

sub list_categories {
    return [
        {
            category_id => 'category-1',
            slug        => 'general',
            title       => 'General',
            description => 'General forum',
            visibility  => 'public',
            position    => 1,
        },
    ];
}

sub find_category {
    my ( $self, $category_id ) = @_;

    return if $category_id ne 'category-1';

    return $self->list_categories->[0];
}

sub list_category_threads {
    return {
        items => [
            {
                thread_id        => 'thread-1',
                category_id      => 'category-1',
                author_user_id   => 'user-1',
                title            => 'Welcome',
                slug             => 'welcome',
                pinned           => 0,
                visibility       => 'public',
                moderation_state => 'visible',
                locked_at        => undef,
                last_activity_at => '2026-05-23T12:00:00Z',
            },
        ],
        next_cursor => 'thread-cursor',
    };
}

sub list_public_threads {
    return {
        items => [
            {
                thread_id        => 'thread-1',
                category_id      => 'category-1',
                author_user_id   => 'user-1',
                title            => 'Welcome',
                slug             => 'welcome',
                pinned           => 0,
                visibility       => 'public',
                moderation_state => 'visible',
                deleted_at       => undef,
                hidden_at        => undef,
                last_activity_at => '2026-05-23T12:00:00Z',
                created_at       => '2026-05-23T11:00:00Z',
                safe_excerpt     => 'First public post',
            },
            {
                thread_id        => 'thread-hidden',
                category_id      => 'category-1',
                author_user_id   => 'user-1',
                title            => 'Hidden',
                slug             => 'hidden',
                pinned           => 0,
                visibility       => 'public',
                moderation_state => 'hidden',
                deleted_at       => undef,
                hidden_at        => '2026-05-23T12:00:00Z',
                last_activity_at => '2026-05-23T12:00:00Z',
                created_at       => '2026-05-23T11:00:00Z',
                safe_excerpt     => 'private text must not leak',
            },
        ],
        next_cursor => undef,
    };
}

sub find_thread {
    my ( $self, $thread_id ) = @_;

    return if $thread_id ne 'thread-1';

    return {
        thread_id        => 'thread-1',
        category_id      => 'category-1',
        author_user_id   => 'user-1',
        title            => 'Welcome',
        slug             => 'welcome',
        pinned           => 0,
        visibility       => 'public',
        moderation_state => 'visible',
        locked_at        => undef,
        last_activity_at => '2026-05-23T12:00:00Z',
    };
}

sub thread_page {
    my ( $self, $request ) = @_;

    my $thread = $self->find_thread( $request->{thread_id} );

    return { ok => 0, error => 'not_found' } if !$thread;

    return {
        ok     => 1,
        thread => $thread,
        posts  => {
            items => [
                {
                    post_id          => 'post-1',
                    thread_id        => 'thread-1',
                    author_user_id   => 'user-1',
                    position         => 1,
                    visibility       => 'public',
                    moderation_state => 'visible',
                    body             => 'First post',
                },
            ],
            next_cursor => 'post-cursor',
        },
    };
}

sub find_visible_post {
    my ( $self, $post_id ) = @_;

    return if $post_id ne 'post-1';

    return {
        post_id          => 'post-1',
        thread_id        => 'thread-1',
        author_user_id   => 'user-1',
        position         => 1,
        visibility       => 'public',
        moderation_state => 'visible',
        deleted_at       => undef,
    };
}

sub prepare {
    my ( $self, $input ) = @_;

    return { ok => 1, command => { post => { post_id => 'post-created' } } }
      if exists $input->{thread_id};

    return {
        ok      => 1,
        command => { thread => { thread_id => 'thread-created' } }
    };
}

sub create_thread {
    return { ok => 1, thread => { thread_id => 'thread-created' } };
}

sub create_post {
    return { ok => 1, post => { post_id => 'post-created' } };
}

sub create_report {
    my ( $self, $input ) = @_;

    return {
        report_id        => 'report-created',
        reporter_user_id => $input->{reporter_user_id},
        target_type      => $input->{target_type},
        target_id        => $input->{target_id},
        reason           => $input->{reason},
        details          => $input->{details},
        status           => 'open',
        created_at       => '2026-05-23T12:00:00Z',
    };
}

sub list_queue {
    return [
        {
            report_id                  => 'report-1',
            reporter_user_id           => 'user-1',
            target_type                => 'post',
            target_id                  => 'post-1',
            reason                     => 'spam',
            details                    => 'Repeated links',
            status                     => 'open',
            assigned_moderator_user_id => undef,
            created_at                 => '2026-05-23T12:00:00Z',
            resolved_at                => undef,
            resolution                 => undef,
        },
    ];
}

sub list_actions {
    return {
        items => [
            {
                moderation_action_id => 'action-post-hide',
                actor_user_id        => 'moderator-1',
                action_type          => 'post.hidden',
                target_type          => 'post',
                target_id            => 'post-1',
                reason               => 'spam',
                metadata             => {},
                created_at           => '2026-05-23T12:00:00Z',
                reversed_at          => undef,
                reversed_by_user_id  => undef,
            },
        ],
        next_cursor => 'action-cursor',
    };
}

sub list_suspensions {
    return {
        items => [
            {
                suspension_id => 'suspension-1',
                user_id       => 'user-2',
                actor_user_id => 'moderator-1',
                reason        => 'abuse campaign',
                valid_from    => '2026-05-23T12:00:00Z',
                valid_to      => '2026-05-24T12:00:00Z',
                revoked_at    => undef,
                metadata      => {},
            },
        ],
        next_cursor => 'suspension-cursor',
    };
}

sub assign_report {
    my ( $self, $report_id, $moderator_user_id ) = @_;

    return if $report_id ne 'report-1';

    return {
        report_id                  => $report_id,
        assigned_moderator_user_id => $moderator_user_id,
    };
}

sub resolve_report {
    my ( $self, $report_id, $resolution ) = @_;

    return if $report_id ne 'report-1';

    return {
        report_id   => $report_id,
        status      => 'resolved',
        resolved_at => '2026-05-23T12:00:00Z',
        resolution  => $resolution,
    };
}

sub hide_post {
    my ( $self, $input ) = @_;

    return if $input->{post_id} ne 'post-1';

    return {
        ok     => 1,
        action => {
            moderation_action_id => 'action-post-hide',
            action_type          => 'post.hidden',
            target_type          => 'post',
            target_id            => $input->{post_id},
            reason               => $input->{reason},
            reversed_at          => undef,
            reversed_by_user_id  => undef,
        },
    };
}

sub restore_post {
    my ( $self, $input ) = @_;

    return if $input->{post_id} ne 'post-1';

    return {
        ok     => 1,
        action => {
            moderation_action_id => 'action-post-restore',
            action_type          => 'post.restored',
            target_type          => 'post',
            target_id            => $input->{post_id},
            reason               => $input->{reason},
            reversed_at          => undef,
            reversed_by_user_id  => undef,
        },
    };
}

sub lock_thread {
    my ( $self, $input ) = @_;

    return if $input->{thread_id} ne 'thread-1';

    return {
        ok     => 1,
        action => {
            moderation_action_id => 'action-thread-lock',
            action_type          => 'thread.locked',
            target_type          => 'thread',
            target_id            => $input->{thread_id},
            reason               => $input->{reason},
            reversed_at          => undef,
            reversed_by_user_id  => undef,
        },
    };
}

sub unlock_thread {
    my ( $self, $input ) = @_;

    return if $input->{thread_id} ne 'thread-1';

    return {
        ok     => 1,
        action => {
            moderation_action_id => 'action-thread-unlock',
            action_type          => 'thread.unlocked',
            target_type          => 'thread',
            target_id            => $input->{thread_id},
            reason               => $input->{reason},
            reversed_at          => undef,
            reversed_by_user_id  => undef,
        },
    };
}

sub reverse_action {
    my ( $self, $action_id, $reversed_by_user_id ) = @_;

    return if $action_id ne 'action-post-hide';

    return {
        moderation_action_id => $action_id,
        reversed_at          => '2026-05-23T12:00:00Z',
        reversed_by_user_id  => $reversed_by_user_id,
    };
}

sub create_suspension {
    my ( $self, $input ) = @_;

    return if $input->{user_id} ne 'user-2';

    return {
        ok         => 1,
        suspension => {
            suspension_id => 'suspension-1',
            user_id       => $input->{user_id},
            actor_user_id => $input->{actor_user_id},
            reason        => $input->{reason},
            valid_from    => '2026-05-23T12:00:00Z',
            valid_to      => $input->{valid_to},
            revoked_at    => undef,
        },
    };
}

sub revoke_suspension {
    my ( $self, $suspension_id, $actor_user_id ) = @_;

    return if $suspension_id ne 'suspension-1';

    return {
        suspension_id => $suspension_id,
        actor_user_id => $actor_user_id,
        revoked_at    => '2026-05-23T12:00:00Z',
    };
}

sub summary_for_page {
    return {
        authenticated         => 1,
        first_unread_anchor   => 'post-post-1',
        first_unread_position => 1,
        first_unread_post_id  => 'post-1',
        last_read_position    => 0,
        last_visible_position => 1,
        unread_in_page        => 1,
    };
}

sub mark_thread_read {
    my ( $self, $input ) = @_;

    return {
        ok         => 1,
        read_state => {
            user_id            => $input->{user_id},
            thread_id          => $input->{thread_id},
            last_read_position => $input->{last_read_position},
            last_read_at       => '2026-05-23T12:00:00Z',
        },
    };
}

sub list_page_for_user {
    my ( $self, $user_id, $options ) = @_;

    if ( $self->mode eq 'feed' ) {
        return {
            items => [
                {
                    user_id            => $user_id,
                    item_type          => 'thread',
                    item_id            => 'thread-1',
                    created_at         => '2026-05-23T12:00:00Z',
                    rank_score         => 0,
                    visibility_version => 1,
                    permission_version => 1,
                },
            ],
            next_cursor => 'feed-cursor',
        };
    }

    if ( !$options->{target_type} ) {
        return {
            items => [
                {
                    notification_id   => 'notification-1',
                    recipient_user_id => $user_id,
                    created_at        => '2026-05-23T12:00:00Z',
                    read_at           => undef,
                    rank_score        => 0,
                    source_type       => 'post',
                    source_id         => 'post-1',
                    notification_type => 'mention',
                    payload           => {
                        thread_id => 'thread-1',
                        post_id   => 'post-1',
                    },
                },
            ],
            next_cursor => 'notification-cursor',
        };
    }

    return {
        items => [
            {
                bookmark_id => 'bookmark-1',
                user_id     => $user_id,
                target_type => 'thread',
                target_id   => 'thread-1',
                note        => 'Read later',
                created_at  => '2026-05-23T12:00:00Z',
                deleted_at  => undef,
            },
        ],
        next_cursor => 'bookmark-cursor',
    };
}

sub list_page_for_recipient {
    my ( $self, $user_id, $options ) = @_;

    return {
        items => [
            {
                mention_id         => 'mention-1',
                source_type        => 'post',
                source_id          => 'post-1',
                actor_id           => 'user-2',
                mentioned_user_id  => $user_id,
                mentioned_username => 'giacomo',
                created_at         => '2026-05-23T12:00:00Z',
            },
        ],
        next_cursor => 'mention-cursor',
    };
}

sub mark_read {
    my ( $self, $notification_id, $recipient_user_id ) = @_;

    return { ok => 0, error => 'not_found' } if $notification_id eq 'missing';

    return {
        ok                => 1,
        notification_id   => $notification_id,
        recipient_user_id => $recipient_user_id,
        read_at           => '2026-05-23T12:00:00Z',
    };
}

sub record_for_source {
    my ( $self, $input ) = @_;

    return {
        ok      => 1,
        created => [
            {
                source_type => $input->{source_type},
                source_id   => $input->{source_id},
                actor_id    => $input->{actor_id},
            },
        ],
        skipped => [],
    };
}

sub save_bookmark {
    my ( $self, $input ) = @_;

    return {
        bookmark_id => 'bookmark-1',
        user_id     => $input->{user_id},
        target_type => $input->{target_type},
        target_id   => $input->{target_id},
        note        => $input->{note} || q{},
        created_at  => '2026-05-23T12:00:00Z',
        deleted_at  => undef,
    };
}

sub remove_for_user_target {
    my ( $self, $input ) = @_;

    return {
        ok          => 1,
        bookmark_id => 'bookmark-1',
        target_type => $input->{target_type},
        target_id   => $input->{target_id},
        deleted_at  => '2026-05-23T12:00:00Z',
    };
}

sub status_for_user_target {
    my ( $self, $user_id, $target_type, $target_id ) = @_;

    return { bookmarked => 0, subscribed => 0, muted => 0 } if !$user_id;

    return { bookmarked => 0, subscribed => 0, muted => 0 }
      if $target_type eq 'thread' && $target_id eq 'thread-1';

    return { bookmarked => 0, subscribed => 0, muted => 0 };
}

sub save_subscription {
    my ( $self, $input ) = @_;

    return {
        subscription_id => 'subscription-1',
        user_id         => $input->{user_id},
        target_type     => $input->{target_type},
        target_id       => $input->{target_id},
        preference      => $input->{preference} || 'all',
        created_at      => '2026-05-23T12:00:00Z',
        muted_at        => undef,
        revoked_at      => undef,
    };
}

sub mute_for_user_target {
    return {
        ok              => 1,
        subscription_id => 'subscription-1',
        muted_at        => '2026-05-23T12:00:00Z',
    };
}

sub revoke_for_user_target {
    return {
        ok              => 1,
        subscription_id => 'subscription-1',
        revoked_at      => '2026-05-23T12:00:00Z',
    };
}

sub next_position {
    return 2;
}

sub search {
    return [
        {
            entity_type => 'thread',
            entity_id   => 'thread-1',
            title       => 'Welcome',
            body        => 'First post',
            visibility  => 'public',
            indexed_at  => '2026-05-23T12:00:00Z',
        },
    ];
}

sub autocomplete {
    return [
        {
            entity_type => 'thread',
            entity_id   => 'thread-1',
            title       => 'Welcome',
            body        => 'First post must not be exposed here',
            visibility  => 'public',
            indexed_at  => '2026-05-23T12:00:00Z',
        },
    ];
}

sub check {
    return { ok => 1 };
}

1;
