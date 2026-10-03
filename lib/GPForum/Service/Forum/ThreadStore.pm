# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::ThreadStore;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $SCHEMA_VERSION         => 1;
const my $THREAD_AGGREGATE       => 'thread';
const my $POST_AGGREGATE         => 'post';
const my $THREAD_ID_CONSTRAINT   => 'threads_pkey';
const my $POST_ID_CONSTRAINT     => 'posts_pkey';
const my $BODY_ID_CONSTRAINT     => 'post_bodies_pkey';
const my $REVISION_ID_CONSTRAINT => 'post_revisions_pkey';
const my $COUNTER_ID_CONSTRAINT  => 'thread_counters_pkey';
const my $THREAD_LOCK_SQL => join q{ },
  'SELECT deleted_at, locked_at, moderation_state',
  'FROM threads WHERE thread_id = ? FOR UPDATE';

# ThreadDetailReader shows a thread only in these states, so the workflow
# lets an author's write through only in these. Any other reads as not found.
const my %EDITABLE_STATE => ( locked => 1, visible => 1 );

# What each write needs of the thread's deletion: a restore a deleted thread,
# a title edit, a move and a delete a live one.
const my $NEEDS_LIVE    => 0;
const my $NEEDS_DELETED => 1;

has clock      => sub { return GPForum::Service::Clock->new; };
has schema     => undef;
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};

sub create_thread ( $self, $command ) {
    my $result = $self->schema->txn_do(
        sub {
            return $self->_insert_thread($command);
        }
    );

    return {
        ok      => 1,
        post    => $result->{post},
        skipped => $result->{skipped},
        thread  => $result->{thread},
    };
}

sub edit_thread ( $self, $command ) {
    return $self->schema->txn_do(
        sub {
            return $self->_update_thread($command);
        }
    );
}

sub delete_thread ( $self, $command ) {
    return $self->schema->txn_do(
        sub {
            return $self->_soft_delete_thread($command);
        }
    );
}

sub restore_thread ( $self, $command ) {
    return $self->schema->txn_do(
        sub {
            return $self->_undelete_thread($command);
        }
    );
}

sub move_thread ( $self, $command ) {
    return $self->schema->txn_do(
        sub {
            return $self->_move_thread($command);
        }
    );
}

sub _insert_thread ( $self, $command ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_thread_rows($command); },
      );
    if ($created) {
        return $self->_finish_created_thread($created);
    }

    return $self->_thread_after_conflict( $command, $error );
}

sub _finish_created_thread ( $self, $created ) {
    if ( $created->{skipped} ) {
        return $created;
    }

    return $self->_finish_new_thread( $created->{command}, $created );
}

sub _create_thread_rows ( $self, $command ) {
    my $thread =
      $self->schema->resultset('Thread')->create( $command->{thread} );

    return $self->_insert_or_retry_opening( $command, $thread );
}

sub _insert_or_retry_opening ( $self, $command, $thread ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_opening_rows( $command, $thread ); },
      );
    if ($created) {
        return $created;
    }

    return $self->_opening_after_conflict( $command, $thread, $error );
}

sub _create_opening_rows ( $self, $command, $thread ) {
    my $post = $self->schema->resultset('Post')->create( $command->{post} );

    return $self->_insert_or_retry_opening_copy(
        {
            command => $command,
            post    => $post,
            thread  => $thread,
        }
    );
}

sub _insert_or_retry_opening_copy ( $self, $ctx ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_opening_copy($ctx); },
      );
    if ($created) {
        return $created;
    }

    return $self->_opening_copy_after_conflict( $ctx, $error );
}

sub _create_opening_copy ( $self, $ctx ) {
    $self->schema->resultset('PostBody')->create( $ctx->{command}{body} );
    $self->schema->resultset('PostRevision')
      ->create( $ctx->{command}{revision} );
    $self->schema->resultset('ThreadCounter')
      ->create( $ctx->{command}{counter} );
    $self->_point_opening_post($ctx);

    return {
        command => $ctx->{command},
        post    => $ctx->{post},
        thread  => $ctx->{thread},
    };
}

sub _create_opening_tail ( $self, $ctx ) {
    $self->schema->resultset('PostRevision')
      ->create( $ctx->{command}{revision} );
    $self->schema->resultset('ThreadCounter')
      ->create( $ctx->{command}{counter} );
    $self->_point_opening_post($ctx);

    return {
        command => $ctx->{command},
        post    => $ctx->{post},
        thread  => $ctx->{thread},
    };
}

sub _point_opening_post ( $self, $ctx ) {
    _update_row(
        $ctx->{post},
        {
            current_body_id     => $ctx->{command}{body}{body_id},
            current_revision_id => $ctx->{command}{revision}{revision_id},
        }
    );

    return;
}

sub _opening_copy_after_conflict ( $self, $ctx, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( _body_id_conflict($error) ) {
        return $self->_retry_or_reuse_opening_body($ctx);
    }
    if ( _revision_id_conflict($error) ) {
        return $self->_retry_or_reuse_opening_revision($ctx);
    }

    return $self->_opening_counter_after_conflict( $ctx, $error );
}

sub _retry_or_reuse_opening_body ( $self, $ctx ) {
    my $stored = $self->_find_body( $ctx->{command}{body}{body_id} );
    if ( $self->_same_open_body( $stored, $ctx->{command} ) ) {
        return $self->_retry_opening_tail($ctx);
    }

    return $self->_retry_opening_body_id($ctx);
}

sub _same_open_body ( $self, $stored, $command ) {
    if ( !$stored ) {
        return 0;
    }

    return _same_text( _column( $stored, 'post_id' ),
        $command->{body}{post_id} );
}

sub _retry_opening_body_id ( $self, $ctx ) {
    my $retry = $self->_command_with_new_body_id( $ctx->{command} );
    my ( $created, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            return $self->_create_opening_copy(
                {
                    command => $retry,
                    post    => $ctx->{post},
                    thread  => $ctx->{thread},
                }
            );
        },
    );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _command_with_new_body_id ( $self, $command ) {
    my $body_id = $self->id_service->uuid;

    return {
        %{$command},
        body     => { %{ $command->{body} },     body_id         => $body_id },
        post     => { %{ $command->{post} },     current_body_id => $body_id },
        revision => { %{ $command->{revision} }, body_id         => $body_id },
    };
}

sub _retry_or_reuse_opening_revision ( $self, $ctx ) {
    my $stored =
      $self->_find_revision( $ctx->{command}{revision}{revision_id} );
    if ( $self->_same_open_revision( $stored, $ctx->{command} ) ) {
        return $self->_retry_opening_counter($ctx);
    }

    return $self->_retry_opening_revision_id($ctx);
}

sub _same_open_revision ( $self, $stored, $command ) {
    if ( !$stored ) {
        return 0;
    }

    return _same_text( _column( $stored, 'post_id' ),
        $command->{revision}{post_id} );
}

sub _retry_opening_revision_id ( $self, $ctx ) {
    my $retry = $self->_command_with_new_revision_id( $ctx->{command} );
    my ( $created, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            return $self->_create_opening_tail(
                {
                    command => $retry,
                    post    => $ctx->{post},
                    thread  => $ctx->{thread},
                }
            );
        },
    );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _command_with_new_revision_id ( $self, $command ) {
    my $revision_id = $self->id_service->uuid;

    return {
        %{$command},
        post => { %{ $command->{post} }, current_revision_id => $revision_id },
        revision => { %{ $command->{revision} }, revision_id => $revision_id },
    };
}

sub _retry_opening_tail ( $self, $ctx ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_opening_tail($ctx); },
      );
    if ($created) {
        return $created;
    }

    return $self->_opening_copy_after_conflict( $ctx, $error );
}

sub _retry_opening_counter ( $self, $ctx ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_opening_counter($ctx); },
      );
    if ($created) {
        return $created;
    }

    return $self->_opening_counter_after_conflict( $ctx, $error );
}

sub _opening_counter_after_conflict ( $self, $ctx, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_counter_id_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_reuse_opening_counter($ctx);
}

sub _reuse_opening_counter ( $self, $ctx ) {
    $self->_point_opening_post($ctx);

    return {
        command => $ctx->{command},
        post    => $ctx->{post},
        thread  => $ctx->{thread},
    };
}

sub _create_opening_counter ( $self, $ctx ) {
    $self->schema->resultset('ThreadCounter')
      ->create( $ctx->{command}{counter} );
    $self->_point_opening_post($ctx);

    return {
        command => $ctx->{command},
        post    => $ctx->{post},
        thread  => $ctx->{thread},
    };
}

sub _find_body ( $self, $body_id ) {
    return $self->schema->resultset('PostBody')
      ->find( { body_id => $body_id } );
}

sub _find_revision ( $self, $revision_id ) {
    return $self->schema->resultset('PostRevision')
      ->find( { revision_id => $revision_id } );
}

sub _body_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $BODY_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _revision_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $REVISION_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _counter_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $COUNTER_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _opening_after_conflict ( $self, $command, $thread, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_post_id_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_or_reuse_opening_post( $command, $thread );
}

sub _retry_or_reuse_opening_post ( $self, $command, $thread ) {
    my $post = $self->_find_post( $command->{post}{post_id} );
    if ( $self->_same_open_post( $post, $command ) ) {
        return $self->_finish_leftover_opening( $command, $thread, $post );
    }

    return $self->_retry_opening_post_id( $command, $thread );
}

sub _finish_leftover_opening ( $self, $command, $thread, $post ) {
    my $body = $self->_find_body( $command->{body}{body_id} );
    if ( $self->_same_open_body( $body, $command ) ) {
        return {
            command => $command,
            post    => $post,
            skipped => 1,
            thread  => $thread,
        };
    }

    return $self->_insert_or_retry_opening_copy(
        {
            command => $command,
            post    => $post,
            thread  => $thread,
        }
    );
}

sub _same_open_post ( $self, $post, $command ) {
    if ( !$post ) {
        return 0;
    }

    return _same_text( _column( $post, 'thread_id' ),
        $command->{post}{thread_id} );
}

sub _retry_opening_post_id ( $self, $command, $thread ) {
    my $retry = $self->_command_with_new_post_id($command);
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_opening_rows( $retry, $thread ); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _command_with_new_post_id ( $self, $command ) {
    my $post_id = $self->id_service->uuid;

    return {
        %{$command},
        body     => { %{ $command->{body} },     post_id => $post_id },
        post     => { %{ $command->{post} },     post_id => $post_id },
        revision => { %{ $command->{revision} }, post_id => $post_id },
    };
}

sub _post_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $POST_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _finish_new_thread ( $self, $command, $created ) {
    my $correlation_id = $self->id_service->uuid;
    my $thread_event_id =
      $self->_record_thread_event( $command, $correlation_id );
    $self->_record_post_event( $command, $correlation_id, $thread_event_id );
    $self->_record_audit( $command, $correlation_id );

    return $created;
}

sub _thread_after_conflict ( $self, $command, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_thread_id_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_or_reuse_thread($command);
}

sub _retry_or_reuse_thread ( $self, $command ) {
    my $thread = $self->_find_thread( $command->{thread}{thread_id} );
    if ( $self->_same_open_thread( $thread, $command ) ) {
        return $self->_finish_leftover_thread( $command, $thread );
    }

    return $self->_retry_thread_id($command);
}

sub _finish_leftover_thread ( $self, $command, $thread ) {
    my $post = $self->_find_post( $command->{post}{post_id} );
    if ( $self->_same_open_post( $post, $command ) ) {
        return {
            command => $command,
            post    => $post,
            skipped => 1,
            thread  => $thread,
        };
    }

    return $self->_insert_or_retry_opening( $command, $thread );
}

sub _same_open_thread ( $self, $thread, $command ) {
    if ( !$thread ) {
        return 0;
    }
    if (
        !_same_text(
            _column( $thread, 'category_id' ),
            $command->{thread}{category_id}
        )
      )
    {
        return 0;
    }

    return _same_text( _column( $thread, 'slug' ), $command->{thread}{slug} );
}

sub _retry_thread_id ( $self, $command ) {
    my $retry = $self->_command_with_new_thread_id($command);
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_thread_rows($retry); },
      );
    if ($created) {
        return $self->_finish_new_thread( $retry, $created );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _command_with_new_thread_id ( $self, $command ) {
    my $thread_id = $self->id_service->uuid;

    return {
        %{$command},
        counter => { %{ $command->{counter} }, thread_id => $thread_id },
        post    => { %{ $command->{post} },    thread_id => $thread_id },
        thread  => { %{ $command->{thread} },  thread_id => $thread_id },
    };
}

sub _thread_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $THREAD_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _find_post ( $self, $post_id ) {
    return $self->schema->resultset('Post')->find( { post_id => $post_id } );
}

sub _update_thread ( $self, $command ) {
    my $thread_id = $command->{thread}{thread_id};
    my $refused   = $self->_thread_refusal( $thread_id, $NEEDS_LIVE );
    return $refused if $refused;

    my $existing = $self->_find_thread($thread_id);
    if ( !$existing ) {
        return { ok => 0, error => 'thread not found' };
    }
    if ( _title_unchanged( $existing, $command ) ) {
        return _skipped_thread($existing);
    }

    my $thread         = $self->_apply_title( $existing, $command );
    my $correlation_id = $self->id_service->uuid;
    $self->_record_update_event( $command, $thread, $correlation_id );
    $self->_record_update_audit( $command, $thread, $correlation_id );

    return { ok => 1, thread => $thread };
}

# The workflow checked the thread before this row lock; a moderator may have
# locked or hidden it since, or its author deleted or restored it in another
# tab. The row lock orders the write against those writes, which take
# FOR UPDATE too, and returns the thread as they committed it, to be checked
# again. A schema whose storage gives no handle has nothing to lock or
# re-check: a move, a delete and a restore still check the row they find.
sub _thread_refusal ( $self, $thread_id, $needs_deleted ) {
    my $dbh = _schema_dbh( $self->schema );
    if ( !$dbh ) {
        return undef;
    }

    return _thread_store_block(
        $dbh->selectrow_hashref( $THREAD_LOCK_SQL, undef, $thread_id ),
        $needs_deleted );
}

# What the workflow's check said, in its words. A hidden or missing thread is
# not found, and so is one deleted for a title edit, a move or a delete, even
# to its author, who must restore it first, or one live for a restore. A
# locked thread is locked, for a restore too. Authorship is not read again:
# nothing ever changes it.
sub _thread_store_block ( $thread, $needs_deleted ) {
    if (   !$thread
        || _deleted_flag($thread) != $needs_deleted
        || !exists $EDITABLE_STATE{ $thread->{moderation_state} // q{} } )
    {
        return { ok => 0, error => 'thread not found' };
    }
    if ( defined $thread->{locked_at} ) {
        return { ok => 0, error => 'thread is locked' };
    }

    return undef;
}

sub _deleted_flag ($thread) {
    return defined $thread->{deleted_at} ? $NEEDS_DELETED : $NEEDS_LIVE;
}

sub _move_thread ( $self, $command ) {
    my $thread_id = $command->{thread}{thread_id};
    my $refused   = $self->_thread_refusal( $thread_id, $NEEDS_LIVE );
    return $refused if $refused;

    my $existing = $self->_find_thread($thread_id);
    my $blocked  = _delete_store_block($existing);
    if ($blocked) {
        return $blocked;
    }
    if ( _category_unchanged( $existing, $command ) ) {
        return _skipped_thread($existing);
    }

    $command->{thread}{previous_category_id} =
      _column( $existing, 'category_id' );
    my $thread         = $self->_apply_category( $existing, $command );
    my $correlation_id = $self->id_service->uuid;
    $self->_record_move_event( $command, $thread, $correlation_id );
    $self->_record_move_audit( $command, $thread, $correlation_id );

    return { ok => 1, thread => $thread };
}

sub _find_thread ( $self, $thread_id ) {
    return $self->schema->resultset('Thread')
      ->find( { thread_id => $thread_id } );
}

sub _soft_delete_thread ( $self, $command ) {
    my $thread_id = $command->{thread}{thread_id};
    my $refused   = $self->_thread_refusal( $thread_id, $NEEDS_LIVE );
    return $refused if $refused;

    my $existing = $self->_find_thread($thread_id);
    my $blocked  = _delete_store_block($existing);
    if ($blocked) {
        return $blocked;
    }

    my $thread         = $self->_apply_delete_markers( $existing, $command );
    my $correlation_id = $self->id_service->uuid;
    $self->_record_delete_event( $command, $thread, $correlation_id );
    $self->_record_delete_audit( $command, $thread, $correlation_id );

    return { ok => 1, thread => $thread };
}

sub _undelete_thread ( $self, $command ) {
    my $thread_id = $command->{thread}{thread_id};
    my $refused   = $self->_thread_refusal( $thread_id, $NEEDS_DELETED );
    return $refused if $refused;

    my $existing = $self->_find_thread($thread_id);
    my $blocked  = _restore_store_block($existing);
    if ($blocked) {
        return $blocked;
    }

    my $thread         = $self->_clear_delete_markers($existing);
    my $correlation_id = $self->id_service->uuid;
    $self->_record_restore_event( $command, $thread, $correlation_id );
    $self->_record_restore_audit( $command, $thread, $correlation_id );

    return { ok => 1, thread => $thread };
}

# The row found once the lock is held. With a handle the lock's re-check has
# already answered; a schema without one has only this.
sub _delete_store_block ($existing) {
    if ( !$existing ) {
        return { ok => 0, error => 'thread not found' };
    }
    if ( defined _column( $existing, 'deleted_at' ) ) {
        return { ok => 0, error => 'thread not found' };
    }

    return undef;
}

sub _restore_store_block ($existing) {
    if ( !$existing ) {
        return { ok => 0, error => 'thread not found' };
    }
    if ( !defined _column( $existing, 'deleted_at' ) ) {
        return { ok => 0, error => 'thread not found' };
    }

    return undef;
}

sub _apply_delete_markers ( $self, $thread, $command ) {
    return _update_row(
        $thread,
        {
            deleted_at => $self->clock->now_iso8601,
            deleted_by => $command->{thread}{deleted_by},
            version    => _next_version($thread),
        }
    );
}

sub _clear_delete_markers ( $self, $thread ) {
    return _update_row(
        $thread,
        {
            deleted_at => undef,
            deleted_by => undef,
            version    => _next_version($thread),
        }
    );
}

sub _apply_title ( $self, $thread, $command ) {
    return _update_row(
        $thread,
        {
            slug    => $command->{thread}{slug},
            title   => $command->{thread}{title},
            version => _next_version($thread),
        }
    );
}

sub _apply_category ( $self, $thread, $command ) {
    return _update_row(
        $thread,
        {
            category_id => $command->{thread}{category_id},
            version     => _next_version($thread),
        }
    );
}

sub _title_unchanged ( $existing, $command ) {
    if ( !_same_text( _column( $existing, 'title' ), $command->{thread}{title} )
      )
    {
        return 0;
    }
    if ( !_same_text( _column( $existing, 'slug' ), $command->{thread}{slug} ) )
    {
        return 0;
    }

    return 1;
}

sub _category_unchanged ( $existing, $command ) {
    return _same_text( _column( $existing, 'category_id' ),
        $command->{thread}{category_id} );
}

sub _same_text ( $held, $incoming ) {
    $held     = defined $held     ? $held     : q{};
    $incoming = defined $incoming ? $incoming : q{};

    return $held eq $incoming ? 1 : 0;
}

sub _skipped_thread ($thread) {
    return {
        ok      => 1,
        skipped => 1,
        thread  => $thread,
    };
}

sub _next_version ($thread) {
    my $version = _column( $thread, 'version' ) || 1;

    return $version + 1;
}

sub _update_row ( $row, $changes ) {
    if ( ref $row eq 'HASH' ) {
        @{$row}{ keys %{$changes} } = values %{$changes};

        return $row;
    }

    $row->update($changes);

    return $row;
}

sub _schema_dbh ($schema) {
    my $storage = eval { return $schema->storage; };
    if ( !$storage || !$storage->can('dbh') ) {
        return undef;
    }

    my $dbh = eval { return $storage->dbh; };
    return $dbh;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

sub _record_thread_event ( $self, $command, $correlation_id ) {
    my $event = $self->recorder->record_event(
        event_type        => 'thread.created',
        aggregate_type    => $THREAD_AGGREGATE,
        aggregate_id      => $command->{thread}{thread_id},
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $command->{thread}{author_user_id},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   => _idempotency_key(
            $command, 'thread.created', $command->{thread}{thread_id}
        ),
        payload => {
            thread_id      => $command->{thread}{thread_id},
            category_id    => $command->{thread}{category_id},
            author_user_id => $command->{thread}{author_user_id},
            title          => $command->{thread}{title},
            visibility     => $command->{thread}{visibility},
        },
    );

    return $event->{event_id};
}

sub _record_post_event ( $self, $command, $correlation_id, $causation_id ) {
    $self->recorder->record_event(
        event_type        => 'post.created',
        aggregate_type    => $POST_AGGREGATE,
        aggregate_id      => $command->{post}{post_id},
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $command->{post}{author_user_id},
        correlation_id    => $correlation_id,
        causation_id      => $causation_id,
        idempotency_key   => _idempotency_key(
            $command, 'post.created', $command->{post}{post_id}
        ),
        payload => {
            post_id        => $command->{post}{post_id},
            thread_id      => $command->{post}{thread_id},
            author_user_id => $command->{post}{author_user_id},
            revision_id    => $command->{revision}{revision_id},
        },
    );

    return;
}

sub _record_audit ( $self, $command, $correlation_id ) {
    $self->recorder->record_audit(
        action         => 'thread.created',
        schema_version => $SCHEMA_VERSION,
        actor_id       => $command->{thread}{author_user_id},
        target_type    => $THREAD_AGGREGATE,
        target_id      => $command->{thread}{thread_id},
        correlation_id => $correlation_id,
        metadata       => { title => $command->{thread}{title} },
    );

    return;
}

sub _record_update_event ( $self, $command, $thread, $correlation_id ) {
    my $thread_id = $command->{thread}{thread_id};

    $self->recorder->record_event(
        event_type        => 'thread.updated',
        aggregate_type    => $THREAD_AGGREGATE,
        aggregate_id      => $thread_id,
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $command->{thread}{editor_user_id},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   =>
          _idempotency_key( $command, 'thread.updated', $thread_id ),
        payload => {
            editor_user_id => $command->{thread}{editor_user_id},
            slug      => _column( $thread, 'slug' ) || $command->{thread}{slug},
            thread_id => $thread_id,
            title => _column( $thread, 'title' ) || $command->{thread}{title},
        },
    );

    return;
}

sub _record_update_audit ( $self, $command, $thread, $correlation_id ) {
    $self->recorder->record_audit(
        action         => 'thread.updated',
        schema_version => $SCHEMA_VERSION,
        actor_id       => $command->{thread}{editor_user_id},
        target_type    => $THREAD_AGGREGATE,
        target_id      => $command->{thread}{thread_id},
        correlation_id => $correlation_id,
        metadata       => {
            slug  => _column( $thread, 'slug' )  || $command->{thread}{slug},
            title => _column( $thread, 'title' ) || $command->{thread}{title},
        },
    );

    return;
}

sub _record_delete_event ( $self, $command, $thread, $correlation_id ) {
    my $thread_id = $command->{thread}{thread_id};

    $self->recorder->record_event(
        event_type        => 'thread.deleted',
        aggregate_type    => $THREAD_AGGREGATE,
        aggregate_id      => $thread_id,
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $command->{thread}{deleted_by},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   =>
          _idempotency_key( $command, 'thread.deleted', $thread_id ),
        payload => {
            category_id => _column( $thread, 'category_id' )
              || $command->{thread}{category_id},
            deleted_by => $command->{thread}{deleted_by},
            thread_id  => $thread_id,
        },
    );

    return;
}

sub _record_delete_audit ( $self, $command, $thread, $correlation_id ) {
    $self->recorder->record_audit(
        action         => 'thread.deleted',
        schema_version => $SCHEMA_VERSION,
        actor_id       => $command->{thread}{deleted_by},
        target_type    => $THREAD_AGGREGATE,
        target_id      => $command->{thread}{thread_id},
        correlation_id => $correlation_id,
        metadata       => {
            category_id => _column( $thread, 'category_id' )
              || $command->{thread}{category_id},
        },
    );

    return;
}

sub _record_restore_event ( $self, $command, $thread, $correlation_id ) {
    my $thread_id = $command->{thread}{thread_id};

    $self->recorder->record_event(
        event_type        => 'thread.undeleted',
        aggregate_type    => $THREAD_AGGREGATE,
        aggregate_id      => $thread_id,
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $command->{thread}{restored_by},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   =>
          _idempotency_key( $command, 'thread.undeleted', $thread_id ),
        payload => {
            author_user_id => _column( $thread, 'author_user_id' )
              || $command->{thread}{author_user_id},
            category_id => _column( $thread, 'category_id' )
              || $command->{thread}{category_id},
            restored_by => $command->{thread}{restored_by},
            thread_id   => $thread_id,
        },
    );

    return;
}

sub _record_restore_audit ( $self, $command, $thread, $correlation_id ) {
    $self->recorder->record_audit(
        action         => 'thread.undeleted',
        schema_version => $SCHEMA_VERSION,
        actor_id       => $command->{thread}{restored_by},
        target_type    => $THREAD_AGGREGATE,
        target_id      => $command->{thread}{thread_id},
        correlation_id => $correlation_id,
        metadata       => {
            category_id => _column( $thread, 'category_id' )
              || $command->{thread}{category_id},
        },
    );

    return;
}

sub _record_move_event ( $self, $command, $thread, $correlation_id ) {
    my $thread_id = $command->{thread}{thread_id};

    $self->recorder->record_event(
        event_type        => 'thread.moved',
        aggregate_type    => $THREAD_AGGREGATE,
        aggregate_id      => $thread_id,
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $command->{thread}{editor_user_id},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   =>
          _idempotency_key( $command, 'thread.moved', $thread_id ),
        payload => {
            category_id => _column( $thread, 'category_id' )
              || $command->{thread}{category_id},
            editor_user_id       => $command->{thread}{editor_user_id},
            previous_category_id => $command->{thread}{previous_category_id},
            thread_id            => $thread_id,
        },
    );

    return;
}

sub _record_move_audit ( $self, $command, $thread, $correlation_id ) {
    $self->recorder->record_audit(
        action         => 'thread.moved',
        schema_version => $SCHEMA_VERSION,
        actor_id       => $command->{thread}{editor_user_id},
        target_type    => $THREAD_AGGREGATE,
        target_id      => $command->{thread}{thread_id},
        correlation_id => $correlation_id,
        metadata       => {
            category_id => _column( $thread, 'category_id' )
              || $command->{thread}{category_id},
            previous_category_id => $command->{thread}{previous_category_id},
        },
    );

    return;
}

sub _idempotency_key ( $command, $event_type, $aggregate_id ) {
    if ( defined $command->{idempotency_key}
        && length $command->{idempotency_key} )
    {
        return join q{:}, 'command', $command->{idempotency_key}, $event_type;
    }

    return join q{:}, $event_type, $aggregate_id;
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::ThreadStore - Write a new thread, and its title edits, moves, deletes and restores.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Forum::ThreadStore->new(
        clock      => $clock,
        id_service => $id_service,
        schema     => $schema,
    );

    # The command GPForum::Service::Forum::ThreadComposer->prepare built.
    my $created = $store->create_thread($command);
    my $thread  = $created->{thread};

    my $edited = $store->edit_thread($title_command);
    if ( !$edited->{ok} ) {
        # $edited->{error} is 'thread not found' or 'thread is locked'
    }

    $store->move_thread($move_command);
    $store->delete_thread(
        {
            idempotency_key => $key,
            thread          => {
                category_id => $category_id,
                deleted_by  => $user_id,
                thread_id   => $thread_id,
            },
        }
    );

=head1 DESCRIPTION

The write side of a thread for L<GPForum::Service::Forum::PostingWorkflow>.
It takes the commands L<GPForum::Service::Forum::ThreadComposer> builds,
and the delete and restore commands the workflow builds itself, and writes
each in one transaction, together with its events (in the event log, each
with its outbox message) and its audit row, recorded through
L<GPForum::Infrastructure::EventRecorder>.

A new thread is five rows: the thread, its opening post, the post's body,
its first revision and the thread's reply counter; the post is then pointed
at its body and revision. Each insert runs through
L<GPForum::Infrastructure::UniqueConflict>, under a savepoint inside a live
PostgreSQL transaction, so a primary-key conflict does not abort the
transaction. A conflicting row that belongs to this same command (a thread
with the same category and slug, a post in the same thread, a body or a
revision of the same post, or the thread's counter) is the leftover of an
earlier attempt: it is reused and the rows still missing are inserted after
it. A conflict with another row's id is retried once with a fresh UUID.
When the earlier attempt's thread and opening post are found, nothing more
is written and the answer is marked C<skipped>. Events are recorded only
when this call inserted the thread row.

A title edit, a move, a delete and a restore first lock the thread's row
(C<SELECT ... FOR UPDATE>). The workflow checked the thread before the
transaction; a moderator may have locked or hidden it since, or its author
deleted or restored it in another tab. The lock orders the write against
those writes, which lock the row too, and the store checks the thread again
as they left it: what the workflow checked, in its order and words, except
authorship, which nothing changes. A thread that is missing, hidden (in a
moderation state other than C<visible> and C<locked>) or in the wrong
deletion state -- deleted, for a title edit, a move or a delete, even to its
author; live, for a restore -- is C<thread not found>, and a locked one
C<thread is locked>. A refusal is returned, not thrown, and nothing is
written. Each change increments the thread's C<version>.

Every event's idempotency key is C<command:KEY:TYPE> when the command has an
C<idempotency_key>, and C<TYPE:AGGREGATE_ID> otherwise.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> must be set: the L<DBIx::Class> schema, or
an in-memory double with C<txn_do> and C<resultset>. C<clock> defaults to
L<GPForum::Service::Clock>, C<id_service> to L<GPForum::Infrastructure::Id>,
and C<recorder> to a L<GPForum::Infrastructure::EventRecorder> on the same id
service and schema.

=head2 create_thread

Takes the command L<GPForum::Service::Forum::ThreadComposer/prepare> builds:
a hash reference with C<idempotency_key> and the C<thread>, C<post>,
C<body>, C<revision> and C<counter> records. In one transaction it inserts
them as described above and then, only when it inserted the thread row,
records the C<thread.created> event, the C<post.created> event it causes,
and the C<thread.created> audit row, under one new correlation id.

Returns C<< { ok => 1, thread => $thread, post => $post, skipped => $skipped } >>,
where C<$thread> and C<$post> are the rows written or found, and C<$skipped>
is true when an earlier attempt had already written them. It never returns a
refusal: it dies, and the transaction rolls back, when an insert fails for
any reason other than the conflicts it resolves, or when the retry with a
fresh id fails too.

=head2 edit_thread

Takes the command L<GPForum::Service::Forum::ThreadComposer/prepare_title>
builds: C<idempotency_key> and
C<< thread => { thread_id, title, slug, editor_user_id } >>. In one
transaction, under the thread's row lock, it returns
C<< { ok => 0, error => 'thread not found' } >> when the thread is missing,
deleted, or in a moderation state other than C<visible> and C<locked>, and
C<< { ok => 0, error => 'thread is locked' } >> when it is locked. When the
title and the slug are both unchanged it writes nothing and returns
C<< { ok => 1, skipped => 1, thread => $thread } >>. Otherwise it sets the
title and the slug, records the C<thread.updated> event and audit row, and
returns C<< { ok => 1, thread => $thread } >> with the updated row.

=head2 delete_thread

Takes C<idempotency_key> and
C<< thread => { thread_id, deleted_by, category_id } >>. In one transaction,
under the thread's row lock, it returns
C<< { ok => 0, error => 'thread not found' } >> when the thread is missing,
already deleted, or in a moderation state other than C<visible> and
C<locked>, and C<< { ok => 0, error => 'thread is locked' } >> when it is
locked. Otherwise it sets C<deleted_at> to the clock's now and
C<deleted_by>, records the C<thread.deleted> event and audit row (with the
thread's category, from the row or else from the command), and returns
C<< { ok => 1, thread => $thread } >>.

=head2 restore_thread

Takes C<idempotency_key> and
C<< thread => { thread_id, restored_by, author_user_id, category_id } >>.
In one transaction, under the thread's row lock, it returns
C<< { ok => 0, error => 'thread not found' } >> when the thread is missing,
not deleted, or in a moderation state other than C<visible> and C<locked>,
and C<< { ok => 0, error => 'thread is locked' } >> when it is locked.
Otherwise it clears C<deleted_at> and C<deleted_by>, records
the C<thread.undeleted> event and audit row, and returns
C<< { ok => 1, thread => $thread } >>.

=head2 move_thread

Takes the command L<GPForum::Service::Forum::ThreadComposer/prepare_move>
builds: C<idempotency_key> and
C<< thread => { thread_id, category_id, editor_user_id } >>. In one
transaction, under the thread's row lock, it returns the refusals of
L</delete_thread>, and C<< { ok => 1, skipped => 1, thread => $thread } >>,
writing nothing, when it is already in that category. Otherwise it adds the
current category to the command as C<previous_category_id> in its C<thread>
record (the command is changed in place), sets the new category, records the
C<thread.moved> event and audit row with both categories, and returns
C<< { ok => 1, thread => $thread } >>. Whether the target category exists
and the mover may read it is checked by the workflow, not here.

=head1 DIAGNOSTICS

Refusals are returned as C<< { ok => 0, error => $message } >>, with the
messages C<thread not found> and C<thread is locked>;
L<GPForum::Service::Forum::PostingWorkflow> answers them with the statuses
its own check gives for the same words. Everything else dies and rolls the
transaction back: a database error, a unique violation on a constraint the
store does not resolve, a second conflict after the retry with a fresh id,
or a failure to record an event or an audit row.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::EventRecorder>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::Infrastructure::Row>,
L<GPForum::Infrastructure::Id>, L<GPForum::Service::Clock>, L<Const::Fast>,
L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Conflicts are told apart by the constraint name in the error text
(C<threads_pkey>, C<posts_pkey>, C<post_bodies_pkey>,
C<post_revisions_pkey>, C<thread_counters_pkey>), so a driver must report it
the way PostgreSQL does. A schema whose storage gives no DBI handle takes no
row lock: a title edit through it is not checked again, and a move, a delete
and a restore check only that the row they find is there and is live
(deleted, for a restore). A handle that is given must answer
C<selectrow_hashref> as DBI does; the thread's row lock is read through it.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
