# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ForumWebServices;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has bookmark_removes      => sub { return []; };
has bookmark_saves        => sub { return []; };
has last_moderation_input => sub { return {}; };
has mode                  => 'forum';
has read_marker_writes    => sub { return []; };
has report_assigns        => sub { return []; };
has report_releases       => sub { return []; };
has report_resolves       => sub { return []; };
has action_reverses       => sub { return []; };
has post_hides            => sub { return []; };
has subscription_mutes    => sub { return []; };
has subscription_revokes  => sub { return []; };
has subscription_saves    => sub { return []; };
has suspension_creates    => sub { return []; };
has suspension_revokes    => sub { return []; };

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
                    thread_id            => 'thread-1',
                    category_id          => 'category-1',
                    author_user_id       => 'user-1',
                    author_username      => 'giacomo_forum',
                    author_display_name  => 'Giacomo Picchiarelli',
                    author_profile_label => '@giacomo_forum',
                    title                => 'Welcome',
                    slug                 => 'welcome',
                    visibility           => 'public',
                    moderation_state     => 'visible',
                    last_activity_at     => '2026-05-23T12:00:00Z',
                    safe_excerpt         => 'First public post',
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
        {
            category_id => 'category-2',
            slug        => 'off-topic',
            title       => 'Off-topic',
            description => 'Off-topic forum',
            visibility  => 'public',
            position    => 2,
        },
    ];
}

sub find_category {
    my ( $self, $category_id ) = @_;

    my ($match) =
      grep { $_->{category_id} eq ( $category_id || q{} ) }
      @{ $self->list_categories };

    return $match;
}

sub list_category_threads {
    my ( $self, $request ) = @_;

    return {
        items       => $self->_category_thread_items($request),
        next_cursor => 'thread-cursor',
    };
}

sub list_public_threads {
    return {
        items => [
            {
                thread_id            => 'thread-1',
                category_id          => 'category-1',
                author_user_id       => 'user-1',
                author_username      => 'giacomo_forum',
                author_display_name  => 'Giacomo Picchiarelli',
                author_profile_label => '@giacomo_forum',
                title                => 'Welcome',
                slug                 => 'welcome',
                pinned               => 0,
                visibility           => 'public',
                moderation_state     => 'visible',
                deleted_at           => undef,
                hidden_at            => undef,
                last_activity_at     => '2026-05-23T12:00:00Z',
                created_at           => '2026-05-23T11:00:00Z',
                safe_excerpt         => 'First public post',
            },
            {
                thread_id            => 'thread-hidden',
                category_id          => 'category-1',
                author_user_id       => 'user-1',
                author_username      => 'giacomo_forum',
                author_display_name  => 'Giacomo Picchiarelli',
                author_profile_label => '@giacomo_forum',
                title                => 'Hidden',
                slug                 => 'hidden',
                pinned               => 0,
                visibility           => 'public',
                moderation_state     => 'hidden',
                deleted_at           => undef,
                hidden_at            => '2026-05-23T12:00:00Z',
                last_activity_at     => '2026-05-23T12:00:00Z',
                created_at           => '2026-05-23T11:00:00Z',
                safe_excerpt         => 'private text must not leak',
            },
        ],
        next_cursor => undef,
    };
}

sub find_thread {
    my ( $self, $thread_id, $viewer ) = @_;

    return $self->_deleted_thread_for_viewer( $thread_id, $viewer )
      || $self->_visible_thread($thread_id);
}

sub find_thread_row {
    my ( $self, $thread_id ) = @_;

    if ( ( $thread_id || q{} ) eq 'thread-deleted-1' ) {
        return $self->_deleted_thread_row;
    }

    return $self->_visible_thread($thread_id);
}

sub thread_page {
    my ( $self, $request ) = @_;

    my $thread =
      $self->find_thread( $request->{thread_id}, $request->{viewer_user_id} );

    return { ok => 0, error => 'not_found' } if !$thread;

    return {
        ok     => 1,
        thread => $thread,
        posts  => {
            items       => $self->_thread_page_items($request),
            next_cursor => 'post-cursor',
        },
    };
}

sub _thread_page_items {
    my ( $self, $request ) = @_;

    my @items = ( $self->_visible_thread_post );
    if ( $request->{viewer_user_id} ) {
        push @items, $self->_author_deleted_post;
    }

    return \@items;
}

sub _visible_thread_post {
    return {
        post_id              => 'post-1',
        thread_id            => 'thread-1',
        author_user_id       => 'user-1',
        author_username      => 'giacomo_forum',
        author_display_name  => 'Giacomo Picchiarelli',
        author_profile_label => '@giacomo_forum',
        position             => 1,
        visibility           => 'public',
        moderation_state     => 'visible',
        body                 => 'First post',
    };
}

sub _author_deleted_post {
    return {
        post_id              => 'post-deleted-1',
        thread_id            => 'thread-1',
        author_user_id       => 'user-1',
        author_username      => 'giacomo_forum',
        author_display_name  => 'Giacomo Picchiarelli',
        author_profile_label => '@giacomo_forum',
        position             => 2,
        visibility           => 'public',
        moderation_state     => 'visible',
        deleted_at           => '2026-05-23T12:00:00Z',
        body                 => 'Deleted post',
    };
}

sub _category_thread_items {
    my ( $self, $request ) = @_;

    my @items = ( $self->_visible_thread('thread-1') );
    if ( $request && $request->{viewer_user_id} ) {
        push @items, $self->_deleted_thread_row;
    }

    return \@items;
}

sub _deleted_thread_for_viewer {
    my ( $self, $thread_id, $viewer ) = @_;

    return if ( $thread_id || q{} ) ne 'thread-deleted-1';
    return if !_same_author($viewer);

    return $self->_deleted_thread_row;
}

sub _same_author {
    my ($given) = @_;

    # The readers now receive a resolved Viewer; older callers a bare id.
    my $viewer = ref $given ? $given->user_id : $given;
    return 0 if !defined $viewer || !length $viewer;

    return $viewer eq 'user-1' ? 1 : 0;
}

sub _visible_thread {
    my ( undef, $thread_id ) = @_;

    return if ( $thread_id || q{} ) ne 'thread-1';

    return {
        thread_id            => 'thread-1',
        category_id          => 'category-1',
        category_title       => 'General',
        author_user_id       => 'user-1',
        author_username      => 'giacomo_forum',
        author_display_name  => 'Giacomo Picchiarelli',
        author_profile_label => '@giacomo_forum',
        title                => 'Welcome',
        slug                 => 'welcome',
        pinned               => 0,
        visibility           => 'public',
        moderation_state     => 'visible',
        deleted_at           => undef,
        locked_at            => undef,
        last_activity_at     => '2026-05-23T12:00:00Z',
    };
}

sub _deleted_thread_row {
    return {
        thread_id            => 'thread-deleted-1',
        category_id          => 'category-1',
        author_user_id       => 'user-1',
        author_username      => 'giacomo_forum',
        author_display_name  => 'Giacomo Picchiarelli',
        author_profile_label => '@giacomo_forum',
        title                => 'Deleted thread',
        slug                 => 'deleted-thread',
        pinned               => 0,
        visibility           => 'public',
        moderation_state     => 'visible',
        deleted_at           => '2026-05-23T12:00:00Z',
        locked_at            => undef,
        last_activity_at     => '2026-05-23T12:00:00Z',
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

sub find_post {
    my ( $self, $post_id ) = @_;

    if ( ( $post_id || q{} ) eq 'post-deleted-1' ) {
        return $self->_author_deleted_post;
    }

    return $self->find_visible_post($post_id);
}

sub attachments_for_posts {
    my ( $self, $post_ids ) = @_;

    my %by_post;
    for my $post_id ( @{$post_ids} ) {
        next if $post_id ne 'post-1';
        $by_post{$post_id} = [
            {
                attachment_id     => 'attachment-1',
                byte_size         => 8,
                media_type        => 'image/png',
                original_filename => 'photo.png',
            },
        ];
    }

    return \%by_post;
}

sub delete_linked {
    my ( undef, $input ) = @_;

    if ( $input->{attachment_id} eq 'missing' ) {
        return { error => 'not_found', ok => 0 };
    }

    return {
        attachment => {
            attachment_id => $input->{attachment_id},
            state         => 'deleted',
        },
        ok => 1,
    };
}

sub prepare {
    my ( $self, $input ) = @_;

    my %errors;
    if ( exists $input->{thread_id} ) {
        $errors{body_source} = 'body_source is required'
          if !defined $input->{body_source} || !length $input->{body_source};
        return { ok => 0, errors => \%errors, values => { %{$input} } }
          if %errors;

        return {
            ok      => 1,
            command => { post => { post_id => 'post-created' } }
        };
    }

    $errors{category_id} = 'category_id is required'
      if !defined $input->{category_id} || !length $input->{category_id};
    $errors{title} = 'title is required'
      if !defined $input->{title} || !length $input->{title};
    $errors{body_source} = 'body_source is required'
      if !defined $input->{body_source} || !length $input->{body_source};
    return { ok => 0, errors => \%errors, values => { %{$input} } } if %errors;

    return {
        ok      => 1,
        command => { thread => { thread_id => 'thread-created' } }
    };
}

sub prepare_revision {
    my ( $self, $input ) = @_;

    return { ok => 0, errors => { body_source => 'body is required' } }
      if !defined $input->{body_source} || !length $input->{body_source};

    return {
        ok      => 1,
        command => {
            body => { body_source => $input->{body_source} },
            post => {
                editor_user_id => $input->{editor_user_id},
                post_id        => $input->{post_id}   || 'post-1',
                thread_id      => $input->{thread_id} || 'thread-1',
            },
        },
    };
}

sub prepare_title {
    my ( $self, $input ) = @_;

    my $title = $input->{title};
    if ( !defined $title || !length $title ) {
        return { ok => 0, errors => { title => 'title is required' } };
    }

    return {
        ok      => 1,
        command => {
            thread => {
                editor_user_id => $input->{editor_user_id},
                slug           => 'edited-title',
                thread_id      => $input->{thread_id} || 'thread-1',
                title          => $title,
            },
        },
    };
}

sub prepare_move {
    my ( $self, $input ) = @_;

    my $category_id = $input->{category_id};
    if ( !defined $category_id || !length $category_id ) {
        return {
            ok     => 0,
            errors => { category_id => 'category_id is required' }
        };
    }

    return {
        ok      => 1,
        command => {
            thread => {
                category_id    => $category_id,
                editor_user_id => $input->{editor_user_id},
                thread_id      => $input->{thread_id} || 'thread-1',
            },
        },
    };
}

sub create_thread {
    return { ok => 1, thread => { thread_id => 'thread-created' } };
}

sub edit_thread {
    my ( $self, $command ) = @_;

    return {
        ok     => 1,
        thread => {
            slug      => $command->{thread}{slug}      || 'welcome',
            thread_id => $command->{thread}{thread_id} || 'thread-1',
            title     => $command->{thread}{title}     || 'Edited title',
        },
    };
}

sub delete_thread {
    my ( $self, $command ) = @_;

    return {
        ok     => 1,
        thread => {
            category_id => $command->{thread}{category_id} || 'category-1',
            thread_id   => $command->{thread}{thread_id}   || 'thread-1',
        },
    };
}

sub move_thread {
    my ( $self, $command ) = @_;

    return {
        ok     => 1,
        thread => {
            category_id => $command->{thread}{category_id} || 'category-2',
            thread_id   => $command->{thread}{thread_id}   || 'thread-1',
        },
    };
}

sub create_post {
    return { ok => 1, post => { post_id => 'post-created' } };
}

sub edit_post {
    my ( $self, $command ) = @_;

    return {
        ok   => 1,
        post => {
            post_id   => $command->{post}{post_id}   || 'post-1',
            thread_id => $command->{post}{thread_id} || 'thread-1',
        },
    };
}

sub delete_post {
    my ( $self, $command ) = @_;

    return {
        ok   => 1,
        post => {
            post_id   => $command->{post}{post_id}   || 'post-1',
            thread_id => $command->{post}{thread_id} || 'thread-1',
        },
    };
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
            assigned_moderator_user_id => 'moderator-2',
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

    push @{ $self->report_assigns },
      {
        actor_user_id => $moderator_user_id,
        report_id     => $report_id,
      };
    if ( $report_id ne 'report-1' ) {
        return;
    }

    return {
        report_id                  => $report_id,
        assigned_moderator_user_id => $moderator_user_id,
    };
}

sub release_report {
    my ( $self, $report_id, $moderator_user_id ) = @_;

    push @{ $self->report_releases },
      {
        actor_user_id => $moderator_user_id,
        report_id     => $report_id,
      };
    if ( $report_id ne 'report-1' ) {
        return;
    }

    return {
        report_id                  => $report_id,
        assigned_moderator_user_id => undef,
        actor_user_id              => $moderator_user_id,
    };
}

sub resolve_report {
    my ( $self, $report_id, $resolution ) = @_;

    push @{ $self->report_resolves },
      {
        report_id  => $report_id,
        resolution => $resolution,
      };
    if ( $report_id ne 'report-1' ) {
        return;
    }

    return {
        report_id   => $report_id,
        status      => 'resolved',
        resolved_at => '2026-05-23T12:00:00Z',
        resolution  => $resolution,
    };
}

sub hide_post {
    my ( $self, $input ) = @_;

    $self->last_moderation_input($input);
    push @{ $self->post_hides }, $input;
    if ( $input->{post_id} ne 'post-1' ) {
        return;
    }

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

    if ( _store_restore_command($input) ) {
        return _store_restore_result($input);
    }

    $self->last_moderation_input($input);
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

sub _store_restore_command {
    my ($input) = @_;

    return 0 if ref $input ne 'HASH';

    return exists $input->{post} ? 1 : 0;
}

sub _store_restore_result {
    my ($command) = @_;

    return {
        ok   => 1,
        post => {
            post_id   => $command->{post}{post_id}   || 'post-deleted-1',
            thread_id => $command->{post}{thread_id} || 'thread-1',
        },
    };
}

sub lock_thread {
    my ( $self, $input ) = @_;

    $self->last_moderation_input($input);
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

    $self->last_moderation_input($input);
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

sub hide_thread {
    my ( $self, $input ) = @_;

    $self->last_moderation_input($input);
    if ( $input->{thread_id} ne 'thread-1' ) {
        return;
    }

    return {
        ok     => 1,
        action => {
            moderation_action_id => 'action-thread-hide',
            action_type          => 'thread.hidden',
            target_type          => 'thread',
            target_id            => $input->{thread_id},
            reason               => $input->{reason},
            reversed_at          => undef,
            reversed_by_user_id  => undef,
        },
    };
}

sub restore_thread {
    my ( $self, $input ) = @_;

    if ( _store_restore_thread_command($input) ) {
        return _store_restore_thread_result($input);
    }

    $self->last_moderation_input($input);
    if ( $input->{thread_id} ne 'thread-1' ) {
        return;
    }

    return {
        ok     => 1,
        action => {
            moderation_action_id => 'action-thread-restore',
            action_type          => 'thread.restored',
            target_type          => 'thread',
            target_id            => $input->{thread_id},
            reason               => $input->{reason},
            reversed_at          => undef,
            reversed_by_user_id  => undef,
        },
    };
}

sub _store_restore_thread_command {
    my ($input) = @_;

    return 0 if ref $input ne 'HASH';

    return exists $input->{thread} ? 1 : 0;
}

sub _store_restore_thread_result {
    my ($command) = @_;

    return {
        ok     => 1,
        thread => {
            category_id => $command->{thread}{category_id} || 'category-1',
            thread_id   => $command->{thread}{thread_id} || 'thread-deleted-1',
        },
    };
}

sub reverse_action {
    my ( $self, $action_id, $reversed_by_user_id, $reason ) = @_;

    push @{ $self->action_reverses },
      {
        action_id     => $action_id,
        actor_user_id => $reversed_by_user_id,
        reason        => $reason,
      };
    if ( $action_id ne 'action-post-hide' ) {
        return;
    }

    return {
        moderation_action_id => $action_id,
        reason               => $reason,
        reversed_at          => '2026-05-23T12:00:00Z',
        reversed_by_user_id  => $reversed_by_user_id,
    };
}

sub create_suspension {
    my ( $self, $input ) = @_;

    push @{ $self->suspension_creates }, $input;
    if ( $input->{user_id} ne 'user-2' ) {
        return;
    }

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
    my ( $self, $suspension_id, $actor_user_id, $reason ) = @_;

    push @{ $self->suspension_revokes },
      {
        actor_user_id => $actor_user_id,
        reason        => $reason,
        suspension_id => $suspension_id,
      };
    if ( $suspension_id ne 'suspension-1' ) {
        return;
    }

    return {
        suspension_id => $suspension_id,
        actor_user_id => $actor_user_id,
        reason        => $reason,
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

    push @{ $self->read_marker_writes }, $input;

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
                mention_id          => 'mention-1',
                source_type         => 'post',
                source_id           => 'post-1',
                actor_id            => 'user-2',
                actor_username      => 'reply_author',
                actor_display_name  => 'Reply Author',
                actor_profile_label => '@reply_author',
                mentioned_user_id   => $user_id,
                mentioned_username  => 'giacomo',
                created_at          => '2026-05-23T12:00:00Z',
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
        unread_count      => 0,
    };
}

sub mark_all_read {
    my ( undef, $recipient_user_id ) = @_;

    return {
        duplicate         => 0,
        marked_count      => 1,
        ok                => 1,
        read_at           => '2026-05-23T12:00:00Z',
        recipient_user_id => $recipient_user_id,
        unread_count      => 0,
    };
}

sub unread_count_for_user {
    return 1;
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

    push @{ $self->bookmark_saves }, $input;

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

    push @{ $self->bookmark_removes }, $input;

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

    push @{ $self->subscription_saves }, $input;

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
    my ( $self, $input ) = @_;

    push @{ $self->subscription_mutes }, $input || {};

    return {
        ok              => 1,
        subscription_id => 'subscription-1',
        muted_at        => '2026-05-23T12:00:00Z',
    };
}

sub revoke_for_user_target {
    my ( $self, $input ) = @_;

    push @{ $self->subscription_revokes }, $input || {};

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
    my ( $self, $actor, $query, $options ) = @_;

    return [] if $query eq 'missing';

    if ( $query eq 'many' ) {
        my $limit = $options->{limit} || 3;
        return [
            map {
                {
                    entity_type          => 'thread',
                    entity_id            => 'thread-' . $_,
                    author_user_id       => 'user-1',
                    author_username      => 'giacomo_forum',
                    author_display_name  => 'Giacomo Picchiarelli',
                    author_profile_label => '@giacomo_forum',
                    title                => 'Many result ' . $_,
                    body                 => 'Result body ' . $_,
                    snippet_html         => 'Result body ' . $_,
                    visibility           => 'public',
                    source_created_at    => '2026-05-23T12:00:00Z',
                    indexed_at           => '2026-05-23T12:00:00Z',
                }
            } 1 .. $limit
        ];
    }

    return [
        {
            entity_type          => 'thread',
            entity_id            => 'thread-1',
            author_user_id       => 'user-1',
            author_username      => 'giacomo_forum',
            author_display_name  => 'Giacomo Picchiarelli',
            author_profile_label => '@giacomo_forum',
            title                => 'Welcome',
            body                 => 'First post',
            snippet_html         => '<mark>Welcome</mark> First post',
            visibility           => 'public',
            source_created_at    => '2026-05-23T12:00:00Z',
            indexed_at           => '2026-05-23T12:00:00Z',
        },
    ];
}

sub autocomplete {
    return [
        {
            entity_type          => 'thread',
            entity_id            => 'thread-1',
            author_user_id       => 'user-1',
            author_username      => 'giacomo_forum',
            author_display_name  => 'Giacomo Picchiarelli',
            author_profile_label => '@giacomo_forum',
            title                => 'Welcome',
            body                 => 'First post must not be exposed here',
            visibility           => 'public',
            indexed_at           => '2026-05-23T12:00:00Z',
        },
    ];
}

sub check {
    return { ok => 1 };
}

1;
