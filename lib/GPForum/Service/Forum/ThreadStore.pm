# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::ThreadStore;

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
const my $THREAD_AGGREGATE       => 'thread';
const my $POST_AGGREGATE         => 'post';
const my $THREAD_ID_CONSTRAINT   => 'threads_pkey';
const my $POST_ID_CONSTRAINT     => 'posts_pkey';
const my $BODY_ID_CONSTRAINT     => 'post_bodies_pkey';
const my $REVISION_ID_CONSTRAINT => 'post_revisions_pkey';
const my $COUNTER_ID_CONSTRAINT  => 'thread_counters_pkey';

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
    my $undefined;
    return $undefined;
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
    my $undefined;
    return $undefined;
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
    my $undefined;
    return $undefined;
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
    $self->_lock_thread($thread_id);

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

sub _move_thread ( $self, $command ) {
    my $thread_id = $command->{thread}{thread_id};
    $self->_lock_thread($thread_id);

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
    $self->_lock_thread($thread_id);

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
    $self->_lock_thread($thread_id);

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

sub _delete_store_block ($existing) {
    if ( !$existing ) {
        return { ok => 0, error => 'thread not found' };
    }
    if ( defined _column( $existing, 'deleted_at' ) ) {
        return { ok => 0, error => 'thread not found' };
    }

    my $undefined;
    return $undefined;
}

sub _restore_store_block ($existing) {
    if ( !$existing ) {
        return { ok => 0, error => 'thread not found' };
    }
    if ( !defined _column( $existing, 'deleted_at' ) ) {
        return { ok => 0, error => 'thread not found' };
    }

    my $undefined;
    return $undefined;
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

sub _lock_thread ( $self, $thread_id ) {
    my $dbh = _schema_dbh( $self->schema );
    if ( !$dbh ) {
        return;
    }

    $dbh->selectrow_array(
        'SELECT thread_id FROM threads WHERE thread_id = ? FOR UPDATE',
        undef, $thread_id );

    return;
}

sub _schema_dbh ($schema) {
    my $storage = eval { return $schema->storage; };
    if ( !$storage || !$storage->can('dbh') ) {
        my $undefined;
        return $undefined;
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
