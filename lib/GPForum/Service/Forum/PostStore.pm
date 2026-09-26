# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::PostStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $SCHEMA_VERSION         => 1;
const my $POST_AGGREGATE         => 'post';
const my $FIRST_POSITION         => 1;
const my $COUNTER_SHARD_ID       => 0;
const my $POST_ID_CONSTRAINT     => 'posts_pkey';
const my $BODY_ID_CONSTRAINT     => 'post_bodies_pkey';
const my $REVISION_ID_CONSTRAINT => 'post_revisions_pkey';
const my $THREAD_LOCK_SQL => join q{ },
  'SELECT locked_at, moderation_state FROM threads',
  'WHERE thread_id = ? FOR NO KEY UPDATE';

# ThreadDetailReader shows a thread only in these states, so they are the
# only ones the workflow lets a reply through. Any other reads as not found.
const my %REPLYABLE_STATE => ( locked => 1, visible => 1 );

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

sub create_post ( $self, $command ) {
    my $result = $self->schema->txn_do(
        sub {
            return $self->_insert_post($command);
        }
    );

    # A refusal from under the thread lock has written nothing. Hand it back
    # as it is: folded into the answer below it would read as a success with
    # no post.
    return $result if exists $result->{ok} && !$result->{ok};

    return {
        ok      => 1,
        post    => $result->{post},
        skipped => $result->{skipped},
    };
}

sub edit_post ( $self, $command ) {
    return $self->schema->txn_do(
        sub {
            return $self->_update_post($command);
        }
    );
}

sub delete_post ( $self, $command ) {
    return $self->schema->txn_do(
        sub {
            return $self->_soft_delete_post($command);
        }
    );
}

sub restore_post ( $self, $command ) {
    return $self->schema->txn_do(
        sub {
            return $self->_undelete_post($command);
        }
    );
}

sub _insert_post ( $self, $input_command ) {

    # The thread row lock does two jobs. It hands out positions in commit
    # order, which the PostReader keyset and the ReadState high-water mark
    # depend on: a reply that commits later never takes a lower number. And
    # it orders a reply against a moderator locking or hiding the thread, so
    # the thread is checked again here, as the lock returns it.
    my $refused = $self->_thread_refusal( $input_command->{post}{thread_id} );
    return $refused if $refused;

    return $self->_insert_or_retry_position($input_command);
}

# The in-memory doubles have no handle, so nothing to lock or re-check.
sub _thread_refusal ( $self, $thread_id ) {
    my $dbh = _schema_dbh( $self->schema );
    return if !$dbh;

    return _reply_store_block( _lock_thread( $dbh, $thread_id ) );
}

# The workflow read the thread before this transaction began, and a
# moderator may have locked or hidden it since. Repeat what that check read,
# in its words: a missing or hidden thread is not found, a locked one is
# locked. deleted_at is left out on purpose: an author still sees, and may
# reply to, their own deleted thread, and this must not decide otherwise.
sub _reply_store_block ($thread) {
    if ( !$thread ) {
        return { ok => 0, error => 'thread not found' };
    }
    if ( !exists $REPLYABLE_STATE{ $thread->{moderation_state} // q{} } ) {
        return { ok => 0, error => 'thread not found' };
    }
    if ( defined $thread->{locked_at} ) {
        return { ok => 0, error => 'thread is locked' };
    }

    my $undefined;
    return $undefined;
}

sub _insert_or_retry_position ( $self, $input_command ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_allocated($input_command); },
      );
    if ($created) {
        return $created;
    }

    return $self->_retry_position( $input_command, $error );
}

sub _retry_position ( $self, $input_command, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( _post_id_conflict($error) ) {
        return $self->_retry_or_reuse_post($input_command);
    }

    return $self->_insert_allocated( _unpositioned($input_command) );
}

sub _retry_or_reuse_post ( $self, $command ) {
    my $post = $self->_find_post( $command->{post}{post_id} );
    if ( $self->_same_open_post( $post, $command ) ) {
        return $self->_finish_leftover_post($command);
    }

    return $self->_retry_post_id($command);
}

sub _finish_leftover_post ( $self, $command ) {
    my $body = $self->_find_body( $command->{body}{body_id} );
    if ( $self->_same_open_body( $body, $command ) ) {
        return {
            post    => $self->_find_post( $command->{post}{post_id} ),
            skipped => 1
        };
    }

    return $self->_complete_leftover_copy($command);
}

sub _complete_leftover_copy ( $self, $command ) {
    my $copied = $self->_insert_or_retry_post_copy(
        {
            command => $command,
            post    => $self->_find_post( $command->{post}{post_id} ),
        }
    );

    return $self->_finish_new_post( $copied->{command}, $copied->{post} );
}

sub _same_open_post ( $self, $post, $command ) {
    if ( !$post ) {
        return 0;
    }

    return _same_text( _column( $post, 'thread_id' ),
        $command->{post}{thread_id} );
}

sub _retry_post_id ( $self, $command ) {
    my $retry = $self->_command_with_new_post_id($command);
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_allocated($retry); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
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

sub _insert_allocated ( $self, $input_command ) {
    my $command = $self->_command_with_allocated_position($input_command);
    my $post    = $self->schema->resultset('Post')->create( $command->{post} );
    my $copied  = $self->_insert_or_retry_post_copy(
        {
            command => $command,
            post    => $post,
        }
    );

    return $self->_finish_new_post( $copied->{command}, $copied->{post} );
}

sub _insert_or_retry_post_copy ( $self, $ctx ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_post_copy($ctx); },
      );
    if ($created) {
        return $created;
    }

    return $self->_post_copy_after_conflict( $ctx, $error );
}

sub _create_post_copy ( $self, $ctx ) {
    $self->schema->resultset('PostBody')->create( $ctx->{command}{body} );

    return $self->_create_post_copy_tail($ctx);
}

sub _create_post_copy_tail ( $self, $ctx ) {
    $self->schema->resultset('PostRevision')
      ->create( $ctx->{command}{revision} );
    $self->_increment_counter_shard( $ctx->{command}{counter_shard} );
    $self->_point_post_copy($ctx);

    return $ctx;
}

sub _point_post_copy ( $self, $ctx ) {
    _update_row(
        $ctx->{post},
        {
            current_body_id     => $ctx->{command}{body}{body_id},
            current_revision_id => $ctx->{command}{revision}{revision_id},
        }
    );

    return;
}

sub _post_copy_after_conflict ( $self, $ctx, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( _body_id_conflict($error) ) {
        return $self->_retry_or_reuse_post_copy_body($ctx);
    }
    if ( _revision_id_conflict($error) ) {
        return $self->_retry_or_reuse_post_copy_revision($ctx);
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _retry_or_reuse_post_copy_body ( $self, $ctx ) {
    my $stored = $self->schema->resultset('PostBody')
      ->find( { body_id => $ctx->{command}{body}{body_id} } );
    if ( $self->_same_open_body( $stored, $ctx->{command} ) ) {
        return $self->_retry_post_copy_tail($ctx);
    }

    return $self->_retry_post_copy_body_id($ctx);
}

sub _retry_post_copy_body_id ( $self, $ctx ) {
    my $retry = $self->_command_with_new_body_id( $ctx->{command} );
    my ( $created, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            return $self->_create_post_copy(
                {
                    command => $retry,
                    post    => $ctx->{post},
                }
            );
        },
    );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _command_with_new_body_id ( $self, $command ) {
    my $body_id = $self->id_service->uuid;

    return {
        %{$command},
        body     => { %{ $command->{body} },     body_id => $body_id },
        revision => { %{ $command->{revision} }, body_id => $body_id },
    };
}

sub _retry_post_copy_tail ( $self, $ctx ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_post_copy_tail($ctx); },
      );
    if ($created) {
        return $created;
    }

    return $self->_post_copy_tail_after_conflict( $ctx, $error );
}

sub _post_copy_tail_after_conflict ( $self, $ctx, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_revision_id_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_or_reuse_post_copy_revision($ctx);
}

sub _retry_or_reuse_post_copy_revision ( $self, $ctx ) {
    my $stored = $self->schema->resultset('PostRevision')
      ->find( { revision_id => $ctx->{command}{revision}{revision_id} } );
    if ( $self->_same_open_revision( $stored, $ctx->{command} ) ) {
        return $self->_retry_post_copy_shard($ctx);
    }

    return $self->_retry_post_copy_revision_id($ctx);
}

sub _retry_post_copy_revision_id ( $self, $ctx ) {
    my $retry = $self->_command_with_new_revision_id( $ctx->{command} );
    my ( $created, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            return $self->_create_post_copy_tail(
                {
                    command => $retry,
                    post    => $ctx->{post},
                }
            );
        },
    );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _retry_post_copy_shard ( $self, $ctx ) {
    $self->_increment_counter_shard( $ctx->{command}{counter_shard} );
    $self->_point_post_copy($ctx);

    return $ctx;
}

sub _body_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $BODY_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _finish_new_post ( $self, $command, $post ) {
    my $correlation_id = $self->id_service->uuid;
    $self->_record_post_event( $command, $correlation_id );
    $self->_record_audit( $command, $correlation_id );

    return { post => $post };
}

sub _unpositioned ($command) {
    my %post = %{ $command->{post} };
    $post{position} = 0;

    return { %{$command}, post => \%post };
}

sub _update_post ( $self, $input_command ) {
    my $post_id = $input_command->{post}{post_id};
    $self->_lock_post($post_id);

    my $existing = $self->_find_post($post_id);
    if ( !$existing ) {
        return { ok => 0, error => 'post not found' };
    }
    if ( $self->_body_unchanged( $existing, $input_command ) ) {
        return _skipped_post($existing);
    }

    return $self->_update_or_retry_revision( $existing, $input_command );
}

sub _update_or_retry_revision ( $self, $existing, $input_command ) {
    my ( $updated, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_update_allocated( $existing, $input_command ); },
      );
    if ($updated) {
        return $updated;
    }

    return $self->_revision_after_conflict(
        {
            command  => $input_command,
            error    => $error,
            existing => $existing,
        }
    );
}

sub _revision_after_conflict ( $self, $input ) {
    if (
        !GPForum::Infrastructure::UniqueConflict->is_conflict(
            $input->{error}
        )
      )
    {
        GPForum::Infrastructure::UniqueConflict->rethrow( $input->{error} );
    }
    if ( _revision_id_conflict( $input->{error} ) ) {
        return $self->_retry_or_reuse_edit($input);
    }

    return $self->_update_allocated( $input->{existing},
        _unnumbered( $input->{command} ) );
}

sub _retry_or_reuse_edit ( $self, $input ) {
    my $revision = $self->schema->resultset('PostRevision')->find(
        {
            revision_id => $input->{command}{revision}{revision_id},
        }
    );
    if ( $self->_same_open_revision( $revision, $input->{command} ) ) {
        return $self->_finish_leftover_edit($input);
    }

    return $self->_retry_revision_id($input);
}

sub _finish_leftover_edit ( $self, $input ) {
    if ( $self->_same_edit_pointers( $input->{existing}, $input->{command} ) ) {
        return $self->_reuse_edit($input);
    }

    my $post =
      $self->_apply_revision_pointers( $input->{existing}, $input->{command} );

    return $self->_finish_edit( $input->{command}, $post );
}

sub _same_edit_pointers ( $self, $post, $command ) {
    return _same_text(
        _column( $post, 'current_revision_id' ),
        $command->{revision}{revision_id}
    );
}

sub _same_open_revision ( $self, $revision, $command ) {
    if ( !$revision ) {
        return 0;
    }

    return _same_text( _column( $revision, 'post_id' ),
        $command->{revision}{post_id} );
}

sub _retry_revision_id ( $self, $input ) {
    my $command = $self->_command_with_new_revision_id( $input->{command} );
    my ( $updated, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            return $self->_update_allocated( $input->{existing}, $command );
        },
    );
    if ($updated) {
        return $updated;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _command_with_new_revision_id ( $self, $command ) {
    my $revision_id = $self->id_service->uuid;

    return { %{$command},
        revision => { %{ $command->{revision} }, revision_id => $revision_id },
    };
}

sub _revision_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $REVISION_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _reuse_edit ( $self, $input ) {
    my $revision = $self->schema->resultset('PostRevision')->find(
        {
            revision_id => $input->{command}{revision}{revision_id},
        }
    );
    if ($revision) {
        return {
            ok      => 1,
            post    => $input->{existing},
            skipped => 1,
        };
    }

    GPForum::Infrastructure::UniqueConflict->rethrow( $input->{error} );

    my $undefined;
    return $undefined;
}

sub _update_allocated ( $self, $existing, $input_command ) {
    my $command = $self->_command_with_allocated_revision($input_command);
    $self->_insert_or_reuse_body($command);
    $self->schema->resultset('PostRevision')->create( $command->{revision} );
    my $post = $self->_apply_revision_pointers( $existing, $command );

    return $self->_finish_edit( $command, $post );
}

sub _insert_or_reuse_body ( $self, $command ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_body($command); },
      );
    if ($created) {
        my $undefined;
        return $undefined;
    }

    return $self->_body_after_conflict( $command, $error );
}

sub _create_body ( $self, $command ) {
    return $self->schema->resultset('PostBody')->create( $command->{body} );
}

sub _body_after_conflict ( $self, $command, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( index( $error, $BODY_ID_CONSTRAINT ) < 0 ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_or_reuse_body($command);
}

sub _retry_or_reuse_body ( $self, $command ) {
    my $stored = $self->schema->resultset('PostBody')
      ->find( { body_id => $command->{body}{body_id} } );
    if ( $self->_same_open_body( $stored, $command ) ) {
        return $stored;
    }

    return $self->_retry_body_id($command);
}

sub _same_open_body ( $self, $stored, $command ) {
    if ( !$stored ) {
        return 0;
    }

    return _same_text( _column( $stored, 'post_id' ),
        $command->{body}{post_id} );
}

sub _retry_body_id ( $self, $command ) {
    my $body_id = $self->id_service->uuid;
    $command->{body} = { %{ $command->{body} }, body_id => $body_id };
    $command->{revision} =
      { %{ $command->{revision} }, body_id => $body_id };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_body($command); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _finish_edit ( $self, $command, $post ) {
    my $correlation_id = $self->id_service->uuid;
    $self->_record_edit_event( $command, $post, $correlation_id );
    $self->_record_edit_audit( $command, $post, $correlation_id );

    return { ok => 1, post => $post };
}

sub _unnumbered ($command) {
    my %revision = %{ $command->{revision} };
    $revision{revision_number} = 0;

    return { %{$command}, revision => \%revision };
}

sub _body_unchanged ( $self, $existing, $command ) {
    my $current = $self->_current_body($existing);
    if ( !$current ) {
        return 0;
    }

    return _same_text( _column( $current, 'source_hash' ),
        $command->{body}{source_hash} );
}

sub _current_body ( $self, $post ) {
    my $body_id = _column( $post, 'current_body_id' );
    if ( !_has_text($body_id) ) {
        my $undefined;
        return $undefined;
    }

    return $self->schema->resultset('PostBody')
      ->find( { body_id => $body_id } );
}

sub _skipped_post ($post) {
    return {
        ok      => 1,
        post    => $post,
        skipped => 1,
    };
}

sub _same_text ( $held, $incoming ) {
    $held     = defined $held     ? $held     : q{};
    $incoming = defined $incoming ? $incoming : q{};

    return $held eq $incoming ? 1 : 0;
}

sub _has_text ($value) {
    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

sub _soft_delete_post ( $self, $command ) {
    my $post_id = $command->{post}{post_id};
    $self->_lock_post($post_id);

    my $existing = $self->_find_post($post_id);
    my $blocked  = _delete_store_block($existing);
    if ($blocked) {
        return $blocked;
    }

    my $post = $self->_apply_delete_markers( $existing, $command );
    $self->_decrement_reply_count( _column( $post, 'thread_id' )
          || $command->{post}{thread_id} );

    my $correlation_id = $self->id_service->uuid;
    $self->_record_delete_event( $command, $post, $correlation_id );
    $self->_record_delete_audit( $command, $post, $correlation_id );

    return { ok => 1, post => $post };
}

sub _undelete_post ( $self, $command ) {
    my $post_id = $command->{post}{post_id};
    $self->_lock_post($post_id);

    my $existing = $self->_find_post($post_id);
    my $blocked  = _restore_store_block($existing);
    if ($blocked) {
        return $blocked;
    }

    my $post = $self->_clear_delete_markers($existing);
    $self->_increment_reply_count( _column( $post, 'thread_id' )
          || $command->{post}{thread_id} );

    my $correlation_id = $self->id_service->uuid;
    $self->_record_restore_event( $command, $post, $correlation_id );
    $self->_record_restore_audit( $command, $post, $correlation_id );

    return { ok => 1, post => $post };
}

sub _delete_store_block ($existing) {
    if ( !$existing ) {
        return { ok => 0, error => 'post not found' };
    }
    if ( defined _column( $existing, 'deleted_at' ) ) {
        return { ok => 0, error => 'post not found' };
    }

    my $undefined;
    return $undefined;
}

sub _restore_store_block ($existing) {
    if ( !$existing ) {
        return { ok => 0, error => 'post not found' };
    }
    if ( !defined _column( $existing, 'deleted_at' ) ) {
        return { ok => 0, error => 'post not found' };
    }

    my $undefined;
    return $undefined;
}

sub _apply_delete_markers ( $self, $post, $command ) {
    return _update_row(
        $post,
        {
            deleted_at => $self->clock->now_iso8601,
            deleted_by => $command->{post}{deleted_by},
            version    => $self->_next_version($post),
        }
    );
}

sub _clear_delete_markers ( $self, $post ) {
    return _update_row(
        $post,
        {
            deleted_at => undef,
            deleted_by => undef,
            version    => $self->_next_version($post),
        }
    );
}

sub _decrement_reply_count ( $self, $thread_id ) {
    if ( !defined $thread_id || !length $thread_id ) {
        return;
    }

    $self->_increment_counter_shard(
        {
            reply_count_delta => -1,
            shard_id          => $COUNTER_SHARD_ID,
            thread_id         => $thread_id,
        }
    );

    return;
}

sub _increment_reply_count ( $self, $thread_id ) {
    if ( !defined $thread_id || !length $thread_id ) {
        return;
    }

    $self->_increment_counter_shard(
        {
            reply_count_delta => 1,
            shard_id          => $COUNTER_SHARD_ID,
            thread_id         => $thread_id,
        }
    );

    return;
}

sub _find_post ( $self, $post_id ) {
    return $self->schema->resultset('Post')->find( { post_id => $post_id } );
}

sub _find_body ( $self, $body_id ) {
    return $self->schema->resultset('PostBody')
      ->find( { body_id => $body_id } );
}

sub _apply_revision_pointers ( $self, $post, $command ) {
    my $changes = {
        current_body_id     => $command->{body}{body_id},
        current_revision_id => $command->{revision}{revision_id},
        version             => $self->_next_version($post),
    };

    return _update_row( $post, $changes );
}

sub _next_version ( $self, $post ) {
    my $version = _column( $post, 'version' ) || 1;

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

sub _record_post_event ( $self, $command, $correlation_id ) {
    $self->recorder->record_event(
        event_type        => 'post.created',
        aggregate_type    => $POST_AGGREGATE,
        aggregate_id      => $command->{post}{post_id},
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $command->{post}{author_user_id},
        correlation_id    => $correlation_id,
        causation_id      => undef,
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

sub _record_edit_event ( $self, $command, $post, $correlation_id ) {
    my $post_id = $command->{post}{post_id};

    $self->recorder->record_event(
        event_type        => 'post.updated',
        aggregate_type    => $POST_AGGREGATE,
        aggregate_id      => $post_id,
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $command->{post}{editor_user_id},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   =>
          _idempotency_key( $command, 'post.updated', $post_id ),
        payload => {
            editor_user_id => $command->{post}{editor_user_id},
            post_id        => $post_id,
            revision_id    => $command->{revision}{revision_id},
            thread_id      => _column( $post, 'thread_id' )
              || $command->{post}{thread_id},
        },
    );

    return;
}

sub _record_delete_event ( $self, $command, $post, $correlation_id ) {
    my $post_id = $command->{post}{post_id};

    $self->recorder->record_event(
        event_type        => 'post.deleted',
        aggregate_type    => $POST_AGGREGATE,
        aggregate_id      => $post_id,
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $command->{post}{deleted_by},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   =>
          _idempotency_key( $command, 'post.deleted', $post_id ),
        payload => {
            deleted_by => $command->{post}{deleted_by},
            post_id    => $post_id,
            thread_id  => _column( $post, 'thread_id' )
              || $command->{post}{thread_id},
        },
    );

    return;
}

sub _record_restore_event ( $self, $command, $post, $correlation_id ) {
    my $post_id = $command->{post}{post_id};

    $self->recorder->record_event(
        event_type        => 'post.undeleted',
        aggregate_type    => $POST_AGGREGATE,
        aggregate_id      => $post_id,
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $command->{post}{restored_by},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   =>
          _idempotency_key( $command, 'post.undeleted', $post_id ),
        payload => {
            author_user_id => _column( $post, 'author_user_id' )
              || $command->{post}{author_user_id},
            post_id     => $post_id,
            restored_by => $command->{post}{restored_by},
            thread_id   => _column( $post, 'thread_id' )
              || $command->{post}{thread_id},
        },
    );

    return;
}

sub _increment_counter_shard ( $self, $shard ) {
    my $existing = $self->_existing_shard($shard);
    if ($existing) {
        return $self->_apply_shard_delta( $existing, $shard );
    }

    return $self->_insert_or_reuse_shard($shard);
}

sub _insert_or_reuse_shard ( $self, $shard ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_shard($shard); },
      );
    if ($created) {
        my $undefined;
        return $undefined;
    }

    return $self->_shard_after_conflict( $shard, $error );
}

sub _shard_after_conflict ( $self, $shard, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $existing = $self->_existing_shard($shard);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_apply_shard_delta( $existing, $shard );
}

sub _existing_shard ( $self, $shard ) {
    return $self->_shards->find(
        {
            shard_id  => $shard->{shard_id},
            thread_id => $shard->{thread_id},
        }
    );
}

sub _create_shard ( $self, $shard ) {
    return $self->_shards->create($shard);
}

sub _apply_shard_delta ( $self, $existing, $shard ) {
    if ( ref $existing eq 'HASH' ) {
        $existing->{reply_count_delta} += $shard->{reply_count_delta};
        return;
    }

    $existing->update(
        {
            reply_count_delta =>
              \[ 'reply_count_delta + ?', $shard->{reply_count_delta} ],
            last_updated_at => \'now()',
        }
    );

    return;
}

sub _shards ($self) {
    return $self->schema->resultset('ThreadCounterShard');
}

sub _command_with_allocated_position ( $self, $command ) {
    return $command if _valid_position( $command->{post}{position} );

    my %post = %{ $command->{post} };
    $post{position} = $self->_next_position( $post{thread_id} );

    return { %{$command}, post => \%post };
}

sub _command_with_allocated_revision ( $self, $command ) {
    return $command if _valid_position( $command->{revision}{revision_number} );

    my %revision = %{ $command->{revision} };
    $revision{revision_number} =
      $self->_next_revision_number( $revision{post_id} );

    return { %{$command}, revision => \%revision };
}

# FOR NO KEY UPDATE still queues behind another reply and behind the FOR
# UPDATE that moderation and thread edits take. Unlike FOR UPDATE it does not
# block the FOR KEY SHARE a foreign-key check takes, so a reader's first
# mark-read insert into thread_read_state does not wait for every reply in
# flight to commit. A locking read that waited returns the row as its holder
# committed it (READ COMMITTED), which is what the re-check needs.
sub _lock_thread ( $dbh, $thread_id ) {
    return $dbh->selectrow_hashref( $THREAD_LOCK_SQL, undef, $thread_id );
}

sub _lock_post ( $self, $post_id ) {
    my $dbh = _schema_dbh( $self->schema );
    return if !$dbh;

    $dbh->selectrow_array(
        'SELECT post_id FROM posts WHERE post_id = ? FOR UPDATE',
        undef, $post_id );

    return;
}

sub _next_position ( $self, $thread_id ) {
    my $posts  = $self->schema->resultset('Post');
    my $latest = $posts->search_rs(
        { thread_id => $thread_id },
        {
            order_by => [ { -desc => 'position' }, { -desc => 'post_id' }, ],
            rows     => 1,
        }
    )->single;

    return $FIRST_POSITION if !$latest;

    return _column( $latest, 'position' ) + 1;
}

sub _next_revision_number ( $self, $post_id ) {
    my $revisions = $self->schema->resultset('PostRevision');
    my $search    = $revisions->search_rs( { post_id => $post_id } );

    return _max_revision_number( [ $search->all ] ) + 1;
}

sub _max_revision_number ($revisions) {
    my $latest = 0;
    for my $revision ( @{$revisions} ) {
        $latest = _higher_number( $latest, $revision );
    }

    return $latest;
}

sub _higher_number ( $latest, $revision ) {
    my $number = _column( $revision, 'revision_number' ) || 0;

    return $number > $latest ? $number : $latest;
}

sub _record_audit ( $self, $command, $correlation_id ) {
    $self->recorder->record_audit(
        action         => 'post.created',
        schema_version => $SCHEMA_VERSION,
        actor_id       => $command->{post}{author_user_id},
        target_type    => $POST_AGGREGATE,
        target_id      => $command->{post}{post_id},
        correlation_id => $correlation_id,
        metadata       => { thread_id => $command->{post}{thread_id} },
    );

    return;
}

sub _record_edit_audit ( $self, $command, $post, $correlation_id ) {
    $self->recorder->record_audit(
        action         => 'post.updated',
        schema_version => $SCHEMA_VERSION,
        actor_id       => $command->{post}{editor_user_id},
        target_type    => $POST_AGGREGATE,
        target_id      => $command->{post}{post_id},
        correlation_id => $correlation_id,
        metadata       => {
            revision_id => $command->{revision}{revision_id},
            thread_id   => _column( $post, 'thread_id' )
              || $command->{post}{thread_id},
        },
    );

    return;
}

sub _record_delete_audit ( $self, $command, $post, $correlation_id ) {
    $self->recorder->record_audit(
        action         => 'post.deleted',
        schema_version => $SCHEMA_VERSION,
        actor_id       => $command->{post}{deleted_by},
        target_type    => $POST_AGGREGATE,
        target_id      => $command->{post}{post_id},
        correlation_id => $correlation_id,
        metadata       => {
            thread_id => _column( $post, 'thread_id' )
              || $command->{post}{thread_id},
        },
    );

    return;
}

sub _record_restore_audit ( $self, $command, $post, $correlation_id ) {
    $self->recorder->record_audit(
        action         => 'post.undeleted',
        schema_version => $SCHEMA_VERSION,
        actor_id       => $command->{post}{restored_by},
        target_type    => $POST_AGGREGATE,
        target_id      => $command->{post}{post_id},
        correlation_id => $correlation_id,
        metadata       => {
            thread_id => _column( $post, 'thread_id' )
              || $command->{post}{thread_id},
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

sub _valid_position ($position) {
    return defined $position && $position > 0 ? 1 : 0;
}

sub _schema_dbh ($schema) {
    my $storage = eval { return $schema->storage; };
    my $undefined;
    return $undefined if !$storage || !$storage->can('dbh');

    my $dbh = eval { return $storage->dbh; };
    return $dbh;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

1;
