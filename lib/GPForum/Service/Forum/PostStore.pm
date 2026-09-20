package GPForum::Service::Forum::PostStore;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

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

has clock      => sub { return GPForum::Service::Clock->new; };
has schema     => undef;
has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};

sub create_post {
    my ( $self, $command ) = @_;

    my $result = $self->schema->txn_do(
        sub {
            return $self->_insert_post($command);
        }
    );

    return {
        ok      => 1,
        post    => $result->{post},
        skipped => $result->{skipped},
    };
}

sub edit_post {
    my ( $self, $command ) = @_;

    return $self->schema->txn_do(
        sub {
            return $self->_update_post($command);
        }
    );
}

sub delete_post {
    my ( $self, $command ) = @_;

    return $self->schema->txn_do(
        sub {
            return $self->_soft_delete_post($command);
        }
    );
}

sub restore_post {
    my ( $self, $command ) = @_;

    return $self->schema->txn_do(
        sub {
            return $self->_undelete_post($command);
        }
    );
}

sub _insert_post {
    my ( $self, $input_command ) = @_;

    # Position allocation and the shared reply counter shard both read and
    # then write thread-scoped rows, so serialize writers on the thread row.
    $self->_lock_thread( $input_command->{post}{thread_id} );

    return $self->_insert_or_retry_position($input_command);
}

sub _insert_or_retry_position {
    my ( $self, $input_command ) = @_;

    my $created = eval { return $self->_insert_allocated($input_command); };
    if ($created) {
        return $created;
    }

    return $self->_retry_position( $input_command, $EVAL_ERROR );
}

sub _retry_position {
    my ( $self, $input_command, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( _post_id_conflict($error) ) {
        return $self->_retry_or_reuse_post($input_command);
    }

    return $self->_insert_allocated( _unpositioned($input_command) );
}

sub _retry_or_reuse_post {
    my ( $self, $command ) = @_;

    my $post = $self->_find_post( $command->{post}{post_id} );
    if ( $self->_same_open_post( $post, $command ) ) {
        return $self->_finish_leftover_post($command);
    }

    return $self->_retry_post_id($command);
}

sub _finish_leftover_post {
    my ( $self, $command ) = @_;

    my $body = $self->_find_body( $command->{body}{body_id} );
    if ( $self->_same_open_body( $body, $command ) ) {
        return {
            post    => $self->_find_post( $command->{post}{post_id} ),
            skipped => 1
        };
    }

    return $self->_complete_leftover_copy($command);
}

sub _complete_leftover_copy {
    my ( $self, $command ) = @_;

    my $copied = $self->_insert_or_retry_post_copy(
        {
            command => $command,
            post    => $self->_find_post( $command->{post}{post_id} ),
        }
    );

    return $self->_finish_new_post( $copied->{command}, $copied->{post} );
}

sub _same_open_post {
    my ( $self, $post, $command ) = @_;

    if ( !$post ) {
        return 0;
    }

    return _same_text( _column( $post, 'thread_id' ),
        $command->{post}{thread_id} );
}

sub _retry_post_id {
    my ( $self, $command ) = @_;

    my $retry   = $self->_command_with_new_post_id($command);
    my $created = eval { return $self->_insert_allocated($retry); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _command_with_new_post_id {
    my ( $self, $command ) = @_;

    my $post_id = $self->id_service->uuid;

    return {
        %{$command},
        body     => { %{ $command->{body} },     post_id => $post_id },
        post     => { %{ $command->{post} },     post_id => $post_id },
        revision => { %{ $command->{revision} }, post_id => $post_id },
    };
}

sub _post_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $POST_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _insert_allocated {
    my ( $self, $input_command ) = @_;

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

sub _insert_or_retry_post_copy {
    my ( $self, $ctx ) = @_;

    my $created = eval { return $self->_create_post_copy($ctx); };
    if ($created) {
        return $created;
    }

    return $self->_post_copy_after_conflict( $ctx, $EVAL_ERROR );
}

sub _create_post_copy {
    my ( $self, $ctx ) = @_;

    $self->schema->resultset('PostBody')->create( $ctx->{command}{body} );

    return $self->_create_post_copy_tail($ctx);
}

sub _create_post_copy_tail {
    my ( $self, $ctx ) = @_;

    $self->schema->resultset('PostRevision')
      ->create( $ctx->{command}{revision} );
    $self->_increment_counter_shard( $ctx->{command}{counter_shard} );
    $self->_point_post_copy($ctx);

    return $ctx;
}

sub _point_post_copy {
    my ( $self, $ctx ) = @_;

    _update_row(
        $ctx->{post},
        {
            current_body_id     => $ctx->{command}{body}{body_id},
            current_revision_id => $ctx->{command}{revision}{revision_id},
        }
    );

    return;
}

sub _post_copy_after_conflict {
    my ( $self, $ctx, $error ) = @_;

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
    return;
}

sub _retry_or_reuse_post_copy_body {
    my ( $self, $ctx ) = @_;

    my $stored = $self->schema->resultset('PostBody')
      ->find( { body_id => $ctx->{command}{body}{body_id} } );
    if ( $self->_same_open_body( $stored, $ctx->{command} ) ) {
        return $self->_retry_post_copy_tail($ctx);
    }

    return $self->_retry_post_copy_body_id($ctx);
}

sub _retry_post_copy_body_id {
    my ( $self, $ctx ) = @_;

    my $retry   = $self->_command_with_new_body_id( $ctx->{command} );
    my $created = eval {
        return $self->_create_post_copy(
            {
                command => $retry,
                post    => $ctx->{post},
            }
        );
    };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _command_with_new_body_id {
    my ( $self, $command ) = @_;

    my $body_id = $self->id_service->uuid;

    return {
        %{$command},
        body     => { %{ $command->{body} },     body_id => $body_id },
        revision => { %{ $command->{revision} }, body_id => $body_id },
    };
}

sub _retry_post_copy_tail {
    my ( $self, $ctx ) = @_;

    my $created = eval { return $self->_create_post_copy_tail($ctx); };
    if ($created) {
        return $created;
    }

    return $self->_post_copy_tail_after_conflict( $ctx, $EVAL_ERROR );
}

sub _post_copy_tail_after_conflict {
    my ( $self, $ctx, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( !_revision_id_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_or_reuse_post_copy_revision($ctx);
}

sub _retry_or_reuse_post_copy_revision {
    my ( $self, $ctx ) = @_;

    my $stored = $self->schema->resultset('PostRevision')
      ->find( { revision_id => $ctx->{command}{revision}{revision_id} } );
    if ( $self->_same_open_revision( $stored, $ctx->{command} ) ) {
        return $self->_retry_post_copy_shard($ctx);
    }

    return $self->_retry_post_copy_revision_id($ctx);
}

sub _retry_post_copy_revision_id {
    my ( $self, $ctx ) = @_;

    my $retry   = $self->_command_with_new_revision_id( $ctx->{command} );
    my $created = eval {
        return $self->_create_post_copy_tail(
            {
                command => $retry,
                post    => $ctx->{post},
            }
        );
    };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _retry_post_copy_shard {
    my ( $self, $ctx ) = @_;

    $self->_increment_counter_shard( $ctx->{command}{counter_shard} );
    $self->_point_post_copy($ctx);

    return $ctx;
}

sub _body_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $BODY_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _finish_new_post {
    my ( $self, $command, $post ) = @_;

    my $correlation_id = $self->id_service->uuid;
    $self->_record_post_event( $command, $correlation_id );
    $self->_record_audit( $command, $correlation_id );

    return { post => $post };
}

sub _unpositioned {
    my ($command) = @_;

    my %post = %{ $command->{post} };
    $post{position} = 0;

    return { %{$command}, post => \%post };
}

sub _update_post {
    my ( $self, $input_command ) = @_;

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

sub _update_or_retry_revision {
    my ( $self, $existing, $input_command ) = @_;

    my $updated =
      eval { return $self->_update_allocated( $existing, $input_command ); };
    if ($updated) {
        return $updated;
    }

    return $self->_revision_after_conflict(
        {
            command  => $input_command,
            error    => $EVAL_ERROR,
            existing => $existing,
        }
    );
}

sub _revision_after_conflict {
    my ( $self, $input ) = @_;

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

sub _retry_or_reuse_edit {
    my ( $self, $input ) = @_;

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

sub _finish_leftover_edit {
    my ( $self, $input ) = @_;

    if ( $self->_same_edit_pointers( $input->{existing}, $input->{command} ) ) {
        return $self->_reuse_edit($input);
    }

    my $post =
      $self->_apply_revision_pointers( $input->{existing}, $input->{command} );

    return $self->_finish_edit( $input->{command}, $post );
}

sub _same_edit_pointers {
    my ( $self, $post, $command ) = @_;

    return _same_text(
        _column( $post, 'current_revision_id' ),
        $command->{revision}{revision_id}
    );
}

sub _same_open_revision {
    my ( $self, $revision, $command ) = @_;

    if ( !$revision ) {
        return 0;
    }

    return _same_text( _column( $revision, 'post_id' ),
        $command->{revision}{post_id} );
}

sub _retry_revision_id {
    my ( $self, $input ) = @_;

    my $command = $self->_command_with_new_revision_id( $input->{command} );
    my $updated =
      eval { return $self->_update_allocated( $input->{existing}, $command ); };
    if ($updated) {
        return $updated;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _command_with_new_revision_id {
    my ( $self, $command ) = @_;

    my $revision_id = $self->id_service->uuid;

    return { %{$command},
        revision => { %{ $command->{revision} }, revision_id => $revision_id },
    };
}

sub _revision_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $REVISION_ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _reuse_edit {
    my ( $self, $input ) = @_;

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

    return;
}

sub _update_allocated {
    my ( $self, $existing, $input_command ) = @_;

    my $command = $self->_command_with_allocated_revision($input_command);
    $self->_insert_or_reuse_body($command);
    $self->schema->resultset('PostRevision')->create( $command->{revision} );
    my $post = $self->_apply_revision_pointers( $existing, $command );

    return $self->_finish_edit( $command, $post );
}

sub _insert_or_reuse_body {
    my ( $self, $command ) = @_;

    my $created = eval { return $self->_create_body($command); };
    if ($created) {
        return;
    }

    return $self->_body_after_conflict( $command, $EVAL_ERROR );
}

sub _create_body {
    my ( $self, $command ) = @_;

    return $self->schema->resultset('PostBody')->create( $command->{body} );
}

sub _body_after_conflict {
    my ( $self, $command, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( index( $error, $BODY_ID_CONSTRAINT ) < 0 ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_or_reuse_body($command);
}

sub _retry_or_reuse_body {
    my ( $self, $command ) = @_;

    my $stored = $self->schema->resultset('PostBody')
      ->find( { body_id => $command->{body}{body_id} } );
    if ( $self->_same_open_body( $stored, $command ) ) {
        return $stored;
    }

    return $self->_retry_body_id($command);
}

sub _same_open_body {
    my ( $self, $stored, $command ) = @_;

    if ( !$stored ) {
        return 0;
    }

    return _same_text( _column( $stored, 'post_id' ),
        $command->{body}{post_id} );
}

sub _retry_body_id {
    my ( $self, $command ) = @_;

    my $body_id = $self->id_service->uuid;
    $command->{body} = { %{ $command->{body} }, body_id => $body_id };
    $command->{revision} =
      { %{ $command->{revision} }, body_id => $body_id };
    my $created = eval { return $self->_create_body($command); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _finish_edit {
    my ( $self, $command, $post ) = @_;

    my $correlation_id = $self->id_service->uuid;
    $self->_record_edit_event( $command, $post, $correlation_id );
    $self->_record_edit_audit( $command, $post, $correlation_id );

    return { ok => 1, post => $post };
}

sub _unnumbered {
    my ($command) = @_;

    my %revision = %{ $command->{revision} };
    $revision{revision_number} = 0;

    return { %{$command}, revision => \%revision };
}

sub _body_unchanged {
    my ( $self, $existing, $command ) = @_;

    my $current = $self->_current_body($existing);
    if ( !$current ) {
        return 0;
    }

    return _same_text( _column( $current, 'source_hash' ),
        $command->{body}{source_hash} );
}

sub _current_body {
    my ( $self, $post ) = @_;

    my $body_id = _column( $post, 'current_body_id' );
    if ( !_has_text($body_id) ) {
        return;
    }

    return $self->schema->resultset('PostBody')
      ->find( { body_id => $body_id } );
}

sub _skipped_post {
    my ($post) = @_;

    return {
        ok      => 1,
        post    => $post,
        skipped => 1,
    };
}

sub _same_text {
    my ( $held, $incoming ) = @_;

    $held     = defined $held     ? $held     : q{};
    $incoming = defined $incoming ? $incoming : q{};

    return $held eq $incoming ? 1 : 0;
}

sub _has_text {
    my ($value) = @_;

    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

sub _soft_delete_post {
    my ( $self, $command ) = @_;

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

sub _undelete_post {
    my ( $self, $command ) = @_;

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

sub _delete_store_block {
    my ($existing) = @_;

    if ( !$existing ) {
        return { ok => 0, error => 'post not found' };
    }
    if ( defined _column( $existing, 'deleted_at' ) ) {
        return { ok => 0, error => 'post not found' };
    }

    return;
}

sub _restore_store_block {
    my ($existing) = @_;

    if ( !$existing ) {
        return { ok => 0, error => 'post not found' };
    }
    if ( !defined _column( $existing, 'deleted_at' ) ) {
        return { ok => 0, error => 'post not found' };
    }

    return;
}

sub _apply_delete_markers {
    my ( $self, $post, $command ) = @_;

    return _update_row(
        $post,
        {
            deleted_at => $self->clock->now_iso8601,
            deleted_by => $command->{post}{deleted_by},
            version    => $self->_next_version($post),
        }
    );
}

sub _clear_delete_markers {
    my ( $self, $post ) = @_;

    return _update_row(
        $post,
        {
            deleted_at => undef,
            deleted_by => undef,
            version    => $self->_next_version($post),
        }
    );
}

sub _decrement_reply_count {
    my ( $self, $thread_id ) = @_;

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

sub _increment_reply_count {
    my ( $self, $thread_id ) = @_;

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

sub _find_post {
    my ( $self, $post_id ) = @_;

    return $self->schema->resultset('Post')->find( { post_id => $post_id } );
}

sub _find_body {
    my ( $self, $body_id ) = @_;

    return $self->schema->resultset('PostBody')
      ->find( { body_id => $body_id } );
}

sub _apply_revision_pointers {
    my ( $self, $post, $command ) = @_;

    my $changes = {
        current_body_id     => $command->{body}{body_id},
        current_revision_id => $command->{revision}{revision_id},
        version             => $self->_next_version($post),
    };

    return _update_row( $post, $changes );
}

sub _next_version {
    my ( $self, $post ) = @_;

    my $version = _column( $post, 'version' ) || 1;

    return $version + 1;
}

sub _update_row {
    my ( $row, $changes ) = @_;

    if ( ref $row eq 'HASH' ) {
        @{$row}{ keys %{$changes} } = values %{$changes};

        return $row;
    }

    $row->update($changes);

    return $row;
}

sub _record_post_event {
    my ( $self, $command, $correlation_id ) = @_;

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

sub _record_edit_event {
    my ( $self, $command, $post, $correlation_id ) = @_;

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

sub _record_delete_event {
    my ( $self, $command, $post, $correlation_id ) = @_;

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

sub _record_restore_event {
    my ( $self, $command, $post, $correlation_id ) = @_;

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

sub _increment_counter_shard {
    my ( $self, $shard ) = @_;

    my $existing = $self->_existing_shard($shard);
    if ($existing) {
        return $self->_apply_shard_delta( $existing, $shard );
    }

    return $self->_insert_or_reuse_shard($shard);
}

sub _insert_or_reuse_shard {
    my ( $self, $shard ) = @_;

    my $created = eval { return $self->_create_shard($shard); };
    if ($created) {
        return;
    }

    return $self->_shard_after_conflict( $shard, $EVAL_ERROR );
}

sub _shard_after_conflict {
    my ( $self, $shard, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $existing = $self->_existing_shard($shard);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_apply_shard_delta( $existing, $shard );
}

sub _existing_shard {
    my ( $self, $shard ) = @_;

    return $self->_shards->find(
        {
            shard_id  => $shard->{shard_id},
            thread_id => $shard->{thread_id},
        }
    );
}

sub _create_shard {
    my ( $self, $shard ) = @_;

    return $self->_shards->create($shard);
}

sub _apply_shard_delta {
    my ( $self, $existing, $shard ) = @_;

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

sub _shards {
    my ($self) = @_;

    return $self->schema->resultset('ThreadCounterShard');
}

sub _command_with_allocated_position {
    my ( $self, $command ) = @_;

    return $command if _valid_position( $command->{post}{position} );

    my %post = %{ $command->{post} };
    $post{position} = $self->_next_position( $post{thread_id} );

    return { %{$command}, post => \%post };
}

sub _command_with_allocated_revision {
    my ( $self, $command ) = @_;

    return $command if _valid_position( $command->{revision}{revision_number} );

    my %revision = %{ $command->{revision} };
    $revision{revision_number} =
      $self->_next_revision_number( $revision{post_id} );

    return { %{$command}, revision => \%revision };
}

sub _lock_thread {
    my ( $self, $thread_id ) = @_;

    my $dbh = _schema_dbh( $self->schema );
    return if !$dbh;

    $dbh->selectrow_array(
        'SELECT thread_id FROM threads WHERE thread_id = ? FOR UPDATE',
        undef, $thread_id );

    return;
}

sub _lock_post {
    my ( $self, $post_id ) = @_;

    my $dbh = _schema_dbh( $self->schema );
    return if !$dbh;

    $dbh->selectrow_array(
        'SELECT post_id FROM posts WHERE post_id = ? FOR UPDATE',
        undef, $post_id );

    return;
}

sub _next_position {
    my ( $self, $thread_id ) = @_;

    my $posts  = $self->schema->resultset('Post');
    my $latest = $posts->search(
        { thread_id => $thread_id },
        {
            order_by => [ { -desc => 'position' }, { -desc => 'post_id' }, ],
            rows     => 1,
        }
    )->single;

    return $FIRST_POSITION if !$latest;

    return _column( $latest, 'position' ) + 1;
}

sub _next_revision_number {
    my ( $self, $post_id ) = @_;

    my $revisions = $self->schema->resultset('PostRevision');
    my $search    = $revisions->search( { post_id => $post_id } );

    return _max_revision_number( [ $search->all ] ) + 1;
}

sub _max_revision_number {
    my ($revisions) = @_;

    my $latest = 0;
    for my $revision ( @{$revisions} ) {
        $latest = _higher_number( $latest, $revision );
    }

    return $latest;
}

sub _higher_number {
    my ( $latest, $revision ) = @_;

    my $number = _column( $revision, 'revision_number' ) || 0;

    return $number > $latest ? $number : $latest;
}

sub _record_audit {
    my ( $self, $command, $correlation_id ) = @_;

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

sub _record_edit_audit {
    my ( $self, $command, $post, $correlation_id ) = @_;

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

sub _record_delete_audit {
    my ( $self, $command, $post, $correlation_id ) = @_;

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

sub _record_restore_audit {
    my ( $self, $command, $post, $correlation_id ) = @_;

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

sub _idempotency_key {
    my ( $command, $event_type, $aggregate_id ) = @_;

    if ( defined $command->{idempotency_key}
        && length $command->{idempotency_key} )
    {
        return join q{:}, 'command', $command->{idempotency_key}, $event_type;
    }

    return join q{:}, $event_type, $aggregate_id;
}

sub _valid_position {
    my ($position) = @_;

    return defined $position && $position > 0 ? 1 : 0;
}

sub _schema_dbh {
    my ($schema) = @_;

    my $storage = eval { return $schema->storage; };
    return if !$storage || !$storage->can('dbh');

    my $dbh = eval { return $storage->dbh; };
    return $dbh;
}

sub _column {
    my ( $row, $name ) = @_;

    return                         if !$row;
    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row->can('get_column');

    return;
}

1;
