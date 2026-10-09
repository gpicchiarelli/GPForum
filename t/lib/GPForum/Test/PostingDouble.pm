# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::PostingDouble;

use v5.40;

our $VERSION = '0.001';

# Every collaborator of PostingWorkflow in one object -- the readers, the
# composers, the stores and the mention store -- and the event recorder of
# PostStore: their method names do not collide. `composer => 'invalid'`
# makes every composer refuse; `store => 'refuse'` makes every store answer
# its refusal, and `store => 'die'` makes it die.

sub new ( $class, %mode ) {
    return bless {
        calls    => [],
        composer => $mode{composer} // q{},
        store    => $mode{store}    // q{},
    }, $class;
}

sub _threads {
    return {
        'thread-1' => {
            author_user_id   => 'user-1',
            category_id      => 'general',
            moderation_state => 'visible',
            thread_id        => 'thread-1',
            visibility       => 'members',
        },
        'thread-deleted' => {
            author_user_id   => 'user-1',
            category_id      => 'general',
            deleted_at       => '2026-01-01T00:00:00Z',
            moderation_state => 'visible',
            thread_id        => 'thread-deleted',
        },
        'thread-locked' => {
            author_user_id   => 'user-1',
            locked_at        => '2026-01-01T00:00:00Z',
            moderation_state => 'locked',
            thread_id        => 'thread-locked',
        },
    };
}

sub _posts {
    return {
        'post-1' => {
            author_user_id   => 'user-1',
            moderation_state => 'visible',
            post_id          => 'post-1',
            thread_id        => 'thread-1',
        },
        'post-deleted' => {
            author_user_id   => 'user-1',
            deleted_at       => '2026-01-01T00:00:00Z',
            moderation_state => 'visible',
            post_id          => 'post-deleted',
            thread_id        => 'thread-1',
        },
    };
}

# The workflow passes ids to its readers as the request gave them. A database
# lookup would not ignore the padding; this double does, so a padded input
# still reaches its row.
sub _trimmed ($id) {
    return ( $id // q{} ) =~ s/\A\s+|\s+\z//gmsxr;
}

sub find_category ( $self, $category_id, $viewer ) {
    return undef if $category_id eq 'missing';

    return {
        category_id      => $category_id,
        space_visibility => 'public',
        visibility       => 'members',
    };
}

sub find_thread ( $self, $thread_id, $viewer ) {
    my $thread = _threads()->{ _trimmed($thread_id) };

    return $thread ? { %{$thread} } : undef;
}

sub find_post ( $self, $post_id ) {
    my $post = _posts()->{ _trimmed($post_id) };

    return $post ? { %{$post} } : undef;
}

sub _prepared ( $self, $input, $command ) {
    if ( $self->{composer} eq 'invalid' ) {
        return {
            errors => { field => 'field is invalid' },
            ok     => 0,
            values => { %{$input} },
        };
    }

    return { command => $command, ok => 1 };
}

sub prepare ( $self, $input ) {
    my $post = {
        author_user_id => $input->{author_user_id},
        post_id        => 'post-new',
        thread_id      => $input->{thread_id} // 'thread-new',
    };

    return $self->_prepared(
        $input,
        {
            body            => { body_source => $input->{body_source} },
            idempotency_key => $input->{idempotency_key},
            post            => $post,
            thread          => { thread_id => $post->{thread_id} },
            visibility      => $input->{visibility_floor},
        }
    );
}

sub prepare_revision ( $self, $input ) {
    return $self->_prepared(
        $input,
        {
            body => { body_source => $input->{body_source} },
            post => {
                editor_user_id => $input->{editor_user_id},
                post_id        => $input->{post_id},
                thread_id      => $input->{thread_id},
            },
        }
    );
}

sub prepare_title ( $self, $input ) {
    return $self->_prepared(
        $input,
        {
            thread => {
                slug      => 'new-title',
                thread_id => $input->{thread_id},
                title     => 'New title',
            },
        }
    );
}

sub prepare_move ( $self, $input ) {
    return $self->_prepared(
        $input,
        {
            thread => {
                category_id => $input->{category_id},
                thread_id   => $input->{thread_id},
            },
        }
    );
}

sub _stored ( $self, $refusal, $stored ) {
    die "store died\n"                    if $self->{store} eq 'die';
    return { error => $refusal, ok => 0 } if $self->{store} eq 'refuse';

    return { ok => 1, %{$stored} };
}

sub create_thread ( $self, $command ) {
    return $self->_stored(
        'thread not found',
        {
            post => {
                author_user_id => 'user-1',
                post_id        => 'post-new',
                thread_id      => 'thread-new',
            },
            skipped => undef,
            thread  => {
                category_id => 'general',
                slug        => 'hello',
                thread_id   => 'thread-new',
                title       => 'Hello',
            },
        }
    );
}

sub _thread ( $self, $command, $refusal ) {
    return $self->_stored(
        $refusal,
        {
            thread => {
                category_id => $command->{thread}{category_id} // 'general',
                slug        => 'new-title',
                thread_id   => $command->{thread}{thread_id},
                title       => 'New title',
            },
        }
    );
}

sub edit_thread ( $self, $command ) {
    return $self->_thread( $command, 'thread is locked' );
}

sub move_thread ( $self, $command ) {
    return $self->_thread( $command, 'thread not found' );
}

sub delete_thread ( $self, $command ) {
    return $self->_thread( $command, 'thread not found' );
}

sub restore_thread ( $self, $command ) {
    return $self->_thread( $command, 'thread is locked' );
}

sub _post ( $self, $command, $refusal ) {
    return $self->_stored(
        $refusal,
        {
            post => {
                author_user_id => 'user-1',
                post_id        => $command->{post}{post_id}   // 'post-new',
                thread_id      => $command->{post}{thread_id} // 'thread-1',
            },
        }
    );
}

sub create_post ( $self, $command ) {
    return $self->_post( $command, 'thread is locked' );
}

sub edit_post ( $self, $command ) {
    return $self->_post( $command, 'post is hidden' );
}

sub delete_post ( $self, $command ) {
    return $self->_post( $command, 'post not found' );
}

sub restore_post ( $self, $command ) {
    return $self->_post( $command, 'thread not found' );
}

sub record_for_source ( $self, $input ) {
    return { recorded => 0 };
}

sub record_event ( $self, %event ) {
    push @{ $self->{calls} }, { event => \%event };

    return { event_id => 'event-1' };
}

sub record_audit ( $self, %audit ) {
    push @{ $self->{calls} }, { audit => \%audit };

    return { audit_id => 'audit-1' };
}

# The events and audit rows recorded since the last call, in order.
sub take ($self) {
    my $calls = $self->{calls};
    $self->{calls} = [];

    return $calls;
}

1;
