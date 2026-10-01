# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::PostingWorkflow;

use strict;
use warnings;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use English     qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Service::Forum::Viewer;

use GPForum::Infrastructure::Row;
use GPForum::Service::Forum::Visibility;

our $VERSION = '0.001';

# What a store's refusal under its row locks means: the status the workflow's
# own check gives for the same words. See _store_answer.
const my %STORE_REFUSAL_STATUS => (
    'post is hidden'   => 'forbidden',
    'post not found'   => 'not_found',
    'thread is locked' => 'forbidden',
    'thread not found' => 'not_found',
);

has category_reader      => undef;
has command_idempotency  => undef;
has logger               => undef;
has mention_store        => undef;
has post_composer        => undef;
has post_reader          => undef;
has post_store           => undef;
has thread_composer      => undef;
has thread_detail_reader => undef;
has thread_store         => undef;

sub create_thread {
    my ( $self, $input ) = @_;

    return $self->_run_idempotent_command(
        {
            command_type => 'thread.create',
            input        => $input,
            request      => _thread_request($input),
            response     => sub { return _thread_response_payload(@_); },
            replay       => sub { return _thread_result_from_response(@_); },
            run          => sub { return $self->_create_thread_once($input); },
        }
    );
}

sub _create_thread_once ( $self, $input ) {
    my $command_id  = _command_id($input);
    my $category_id = _trim( $input->{category_id} );
    my $category =
      length $category_id
      ? $self->category_reader->find_category( $category_id, _viewer($input) )
      : undef;
    return _result( status => 'not_found', error => 'category not found' )
      if length $category_id && !$category;

    my $prepared = $self->thread_composer->prepare(
        {
            category_id      => $category_id,
            author_user_id   => $input->{author_user_id},
            title            => $input->{title},
            body_source      => $input->{body_source},
            body_hash        => _body_hash( $input->{body_source} ),
            visibility       => $input->{visibility},
            visibility_floor => _effective_visibility(
                $category, qw(space_visibility visibility)
            ),
            idempotency_key => $command_id,
        }
    );

    return _result( status => 'invalid', prepared => $prepared )
      if !$prepared->{ok};

    my $stored = $self->_store_thread( $prepared->{command} );
    return $stored if !$stored->{ok};

    $self->_record_post_mentions( $stored->{stored}, $prepared->{command} );

    return _result(
        status   => 'ok',
        prepared => $prepared,
        stored   => $stored->{stored},
    );
}

sub create_reply {
    my ( $self, $input ) = @_;

    return $self->_run_idempotent_command(
        {
            command_type => 'reply.create',
            input        => $input,
            request      => _reply_request($input),
            response     => sub { return _reply_response_payload(@_); },
            replay       => sub { return _reply_result_from_response(@_); },
            run          => sub { return $self->_create_reply_once($input); },
        }
    );
}

sub _create_reply_once ( $self, $input ) {
    my $command_id = _command_id($input);
    my $thread =
      $self->thread_detail_reader->find_thread( $input->{thread_id},
        _viewer($input) );
    return _result( status => 'not_found', error => 'thread not found' )
      if !$thread;
    return _result( status => 'forbidden', error => 'thread is locked' )
      if defined _column( $thread, 'locked_at' );

    my $prepared = $self->post_composer->prepare(
        {
            thread_id         => $input->{thread_id},
            author_user_id    => $input->{author_user_id},
            allocate_position => 1,
            body_source       => $input->{body_source},
            body_hash         => _body_hash( $input->{body_source} ),
            idempotency_key   => $command_id,
            visibility        => $input->{visibility},
            visibility_floor  => _effective_visibility(
                $thread, qw(space_visibility category_visibility visibility)
            ),
        }
    );

    return _result( status => 'invalid', prepared => $prepared )
      if !$prepared->{ok};

    my $stored = $self->_store_post( $prepared->{command} );
    return $stored if !$stored->{ok};

    $self->_record_post_mentions( $stored->{stored}, $prepared->{command} );

    return _result(
        status   => 'ok',
        prepared => $prepared,
        stored   => $stored->{stored},
    );
}

sub edit_thread {
    my ( $self, $input ) = @_;

    return $self->_run_idempotent_command(
        {
            command_type => 'thread.edit',
            input        => $input,
            request      => _thread_edit_request($input),
            response     => sub { return _thread_edit_response_payload(@_); },
            replay => sub { return _thread_edit_result_from_response(@_); },
            run    => sub { return $self->_edit_thread_once($input); },
        }
    );
}

sub _edit_thread_once ( $self, $input ) {
    my $blocked = $self->_thread_edit_blocked($input);
    if ($blocked) {
        return $blocked;
    }

    my $prepared = $self->_prepare_title($input);
    if ( !$prepared->{ok} ) {
        return _result( status => 'invalid', prepared => $prepared );
    }

    my $stored = $self->_store_edit_thread( $prepared->{command} );
    if ( !$stored->{ok} ) {
        return $stored;
    }

    return _result(
        status   => 'ok',
        prepared => $prepared,
        stored   => $stored->{stored},
    );
}

sub move_thread {
    my ( $self, $input ) = @_;

    return $self->_run_idempotent_command(
        {
            command_type => 'thread.move',
            input        => $input,
            request      => _thread_move_request($input),
            response     => sub { return _thread_move_response_payload(@_); },
            replay => sub { return _thread_move_result_from_response(@_); },
            run    => sub { return $self->_move_thread_once($input); },
        }
    );
}

sub _move_thread_once ( $self, $input ) {
    my $blocked = $self->_thread_move_blocked($input);
    if ($blocked) {
        return $blocked;
    }

    my $prepared = $self->_prepare_move($input);
    if ( !$prepared->{ok} ) {
        return _result( status => 'invalid', prepared => $prepared );
    }

    my $stored = $self->_store_move_thread( $prepared->{command} );
    if ( !$stored->{ok} ) {
        return $stored;
    }

    return _result(
        status   => 'ok',
        prepared => $prepared,
        stored   => $stored->{stored},
    );
}

sub _thread_move_blocked ( $self, $input ) {
    return $self->_thread_edit_blocked($input)
      || $self->_missing_move_category($input);
}

sub _missing_move_category ( $self, $input ) {
    my $undefined;

    my $category_id = _trim( $input->{category_id} );
    if ( !length $category_id ) {
        return $undefined;
    }
    if ( !$self->category_reader->find_category( $category_id, _viewer($input) )
      )
    {
        return _result( status => 'not_found', error => 'category not found' );
    }

    return $undefined;
}

sub _prepare_move ( $self, $input ) {
    return $self->thread_composer->prepare_move(
        {
            category_id     => $input->{category_id},
            editor_user_id  => $input->{author_user_id},
            idempotency_key => _command_id($input),
            thread_id       => $input->{thread_id},
        }
    );
}

sub delete_thread {
    my ( $self, $input ) = @_;

    return $self->_run_idempotent_command(
        {
            command_type => 'thread.delete',
            input        => $input,
            request      => _thread_delete_request($input),
            response     => sub { return _thread_delete_response_payload(@_); },
            replay => sub { return _thread_delete_result_from_response(@_); },
            run    => sub { return $self->_delete_thread_once($input); },
        }
    );
}

sub restore_thread {
    my ( $self, $input ) = @_;

    return $self->_run_idempotent_command(
        {
            command_type => 'thread.restore',
            input        => $input,
            request      => _thread_delete_request($input),
            response     => sub { return _thread_delete_response_payload(@_); },
            replay => sub { return _thread_delete_result_from_response(@_); },
            run    => sub { return $self->_restore_thread_once($input); },
        }
    );
}

sub _delete_thread_once ( $self, $input ) {
    my $blocked = $self->_thread_edit_blocked($input);
    if ($blocked) {
        return $blocked;
    }

    my $stored =
      $self->_store_delete_thread( $self->_thread_delete_command($input) );
    if ( !$stored->{ok} ) {
        return $stored;
    }

    return _result(
        status => 'ok',
        stored => $stored->{stored},
    );
}

sub _restore_thread_once ( $self, $input ) {
    my $blocked = $self->_restore_thread_blocked($input);
    if ($blocked) {
        return $blocked;
    }

    my $stored =
      $self->_store_restore_thread( $self->_thread_restore_command($input) );
    if ( !$stored->{ok} ) {
        return $stored;
    }

    return _result(
        status => 'ok',
        stored => $stored->{stored},
    );
}

sub _thread_delete_command ( $self, $input ) {
    my $thread =
      $self->thread_detail_reader->find_thread( $input->{thread_id},
        _viewer($input) );

    return {
        idempotency_key => _command_id($input),
        thread          => {
            category_id => _column( $thread, 'category_id' ),
            deleted_by  => $input->{author_user_id},
            thread_id   => $input->{thread_id},
        },
    };
}

sub _thread_restore_command ( $self, $input ) {
    my $thread =
      $self->thread_detail_reader->find_thread( $input->{thread_id},
        _viewer($input) );

    return {
        idempotency_key => _command_id($input),
        thread          => {
            author_user_id => _column( $thread, 'author_user_id' ),
            category_id    => _column( $thread, 'category_id' ),
            restored_by    => $input->{author_user_id},
            thread_id      => $input->{thread_id},
        },
    };
}

sub _prepare_title ( $self, $input ) {
    return $self->thread_composer->prepare_title(
        {
            editor_user_id  => $input->{author_user_id},
            idempotency_key => _command_id($input),
            thread_id       => $input->{thread_id},
            title           => $input->{title},
        }
    );
}

sub _thread_edit_blocked ( $self, $input ) {
    my $thread =
      $self->thread_detail_reader->find_thread( $input->{thread_id},
        _viewer($input) );

    return _missing_edit_thread($thread)
      || _forbidden_thread_edit( $thread, $input );
}

sub _restore_thread_blocked ( $self, $input ) {
    my $thread =
      $self->thread_detail_reader->find_thread( $input->{thread_id},
        _viewer($input) );

    return _missing_restore_thread($thread)
      || _forbidden_thread_edit( $thread, $input );
}

sub _missing_edit_thread ($thread) {
    if ( !_live_thread($thread) ) {
        return _result( status => 'not_found', error => 'thread not found' );
    }

    my $undefined;
    return $undefined;
}

sub _missing_restore_thread ($thread) {
    if ( !_deleted_thread($thread) ) {
        return _result( status => 'not_found', error => 'thread not found' );
    }

    my $undefined;
    return $undefined;
}

sub _live_thread ($thread) {
    if ( !$thread ) {
        return 0;
    }
    if ( defined _column( $thread, 'deleted_at' ) ) {
        return 0;
    }

    return 1;
}

sub _deleted_thread ($thread) {
    if ( !$thread ) {
        return 0;
    }
    if ( defined _column( $thread, 'deleted_at' ) ) {
        return 1;
    }

    return 0;
}

sub _forbidden_thread_edit ( $thread, $input ) {
    if ( !_same_thread_author( $thread, $input ) ) {
        return _result(
            status => 'forbidden',
            error  => 'not the thread author'
        );
    }
    if ( _hidden_thread($thread) ) {
        return _result( status => 'forbidden', error => 'thread is hidden' );
    }
    if ( defined _column( $thread, 'locked_at' ) ) {
        return _result( status => 'forbidden', error => 'thread is locked' );
    }

    my $undefined;
    return $undefined;
}

sub _same_thread_author ( $thread, $input ) {
    my $author = _column( $thread, 'author_user_id' ) || q{};

    return $author eq _trim( $input->{author_user_id} ) ? 1 : 0;
}

sub _hidden_thread ($thread) {
    my $state = _column( $thread, 'moderation_state' ) || q{};

    return $state eq 'hidden' ? 1 : 0;
}

sub edit_post {
    my ( $self, $input ) = @_;

    return $self->_run_idempotent_command(
        {
            command_type => 'post.edit',
            input        => $input,
            request      => _edit_request($input),
            response     => sub { return _reply_response_payload(@_); },
            replay       => sub { return _reply_result_from_response(@_); },
            run          => sub { return $self->_edit_post_once($input); },
        }
    );
}

sub _edit_post_once ( $self, $input ) {
    my $blocked = $self->_edit_blocked($input);
    return $blocked if $blocked;

    my $prepared = $self->_prepare_revision($input);
    return _result( status => 'invalid', prepared => $prepared )
      if !$prepared->{ok};

    my $stored = $self->_store_edit_post( $prepared->{command} );
    return $stored if !$stored->{ok};

    $self->_record_post_mentions( $stored->{stored}, $prepared->{command} );

    return _result(
        status   => 'ok',
        prepared => $prepared,
        stored   => $stored->{stored},
    );
}

sub delete_post {
    my ( $self, $input ) = @_;

    return $self->_run_idempotent_command(
        {
            command_type => 'post.delete',
            input        => $input,
            request      => _delete_request($input),
            response     => sub { return _reply_response_payload(@_); },
            replay       => sub { return _reply_result_from_response(@_); },
            run          => sub { return $self->_delete_post_once($input); },
        }
    );
}

sub restore_post {
    my ( $self, $input ) = @_;

    return $self->_run_idempotent_command(
        {
            command_type => 'post.restore',
            input        => $input,
            request      => _delete_request($input),
            response     => sub { return _reply_response_payload(@_); },
            replay       => sub { return _reply_result_from_response(@_); },
            run          => sub { return $self->_restore_post_once($input); },
        }
    );
}

sub _delete_post_once ( $self, $input ) {
    my $blocked = $self->_edit_blocked($input);
    if ($blocked) {
        return $blocked;
    }

    my $stored = $self->_store_delete_post( $self->_delete_command($input) );
    if ( !$stored->{ok} ) {
        return $stored;
    }

    return _result(
        status => 'ok',
        stored => $stored->{stored},
    );
}

sub _restore_post_once ( $self, $input ) {
    my $blocked = $self->_restore_blocked($input);
    if ($blocked) {
        return $blocked;
    }

    my $stored = $self->_store_restore_post( $self->_restore_command($input) );
    if ( !$stored->{ok} ) {
        return $stored;
    }

    return _result(
        status => 'ok',
        stored => $stored->{stored},
    );
}

sub _delete_command ( $self, $input ) {
    my $post = $self->post_reader->find_post( $input->{post_id} );

    return {
        idempotency_key => _command_id($input),
        post            => {
            deleted_by => $input->{author_user_id},
            post_id    => $input->{post_id},
            thread_id  => _column( $post, 'thread_id' ),
        },
    };
}

sub _restore_command ( $self, $input ) {
    my $post = $self->post_reader->find_post( $input->{post_id} );

    return {
        idempotency_key => _command_id($input),
        post            => {
            author_user_id => _column( $post, 'author_user_id' ),
            post_id        => $input->{post_id},
            restored_by    => $input->{author_user_id},
            thread_id      => _column( $post, 'thread_id' ),
        },
    };
}

sub _prepare_revision ( $self, $input ) {
    my $post = $self->post_reader->find_post( $input->{post_id} );

    return $self->post_composer->prepare_revision(
        {
            body_hash       => _body_hash( $input->{body_source} ),
            body_source     => $input->{body_source},
            edit_reason     => $input->{edit_reason},
            editor_user_id  => $input->{author_user_id},
            idempotency_key => _command_id($input),
            post_id         => $input->{post_id},
            thread_id       => _column( $post, 'thread_id' ),
        }
    );
}

sub _edit_blocked ( $self, $input ) {
    my $post   = $self->post_reader->find_post( $input->{post_id} );
    my $thread = $self->_thread_for_post( $post, $input );

    return _missing_edit_target( $post, $thread )
      || _forbidden_edit( $post, $input, $thread );
}

sub _restore_blocked ( $self, $input ) {
    my $post   = $self->post_reader->find_post( $input->{post_id} );
    my $thread = $self->_thread_for_post( $post, $input );

    return _missing_restore_target( $post, $thread )
      || _forbidden_edit( $post, $input, $thread );
}

sub _thread_for_post ( $self, $post, $input ) {
    my $undefined;
    return $undefined if !$post;

    return $self->thread_detail_reader->find_thread(
        _column( $post, 'thread_id' ),
        _viewer($input) );
}

sub _missing_edit_target ( $post, $thread ) {
    return _result( status => 'not_found', error => 'post not found' )
      if !_live_post($post);
    return _result( status => 'not_found', error => 'thread not found' )
      if !$thread;

    my $undefined;
    return $undefined;
}

sub _missing_restore_target ( $post, $thread ) {
    return _result( status => 'not_found', error => 'post not found' )
      if !_deleted_post($post);
    return _result( status => 'not_found', error => 'thread not found' )
      if !$thread;

    my $undefined;
    return $undefined;
}

sub _live_post ($post) {
    return 0 if !$post;
    return 0 if defined _column( $post, 'deleted_at' );

    return 1;
}

sub _deleted_post ($post) {
    return 0 if !$post;

    return defined _column( $post, 'deleted_at' ) ? 1 : 0;
}

sub _forbidden_edit ( $post, $input, $thread ) {
    return _result( status => 'forbidden', error => 'not the post author' )
      if !_same_author( $post, $input );
    return _result( status => 'forbidden', error => 'post is hidden' )
      if _hidden_post($post);
    return _result( status => 'forbidden', error => 'thread is locked' )
      if defined _column( $thread, 'locked_at' );

    my $undefined;
    return $undefined;
}

sub _same_author ( $post, $input ) {
    my $author = _column( $post, 'author_user_id' ) || q{};

    return $author eq _trim( $input->{author_user_id} ) ? 1 : 0;
}

sub _hidden_post ($post) {
    return 1 if defined _column( $post, 'hidden_at' );

    my $state = _column( $post, 'moderation_state' ) || q{};

    return $state eq 'hidden' ? 1 : 0;
}

sub _run_idempotent_command ( $self, $input ) {
    my $command_key = _command_id( $input->{input} );
    if ( !length $command_key ) {
        return _missing_command_id_result( $input->{input} );
    }

    if ( !$self->command_idempotency ) {
        return $input->{run}->();
    }

    return $self->_guarded_command( $input, $command_key );
}

sub _guarded_command ( $self, $input, $command_key ) {
    my $guarded =
      eval { return $self->_command_guard( $input, $command_key ); };
    if ($EVAL_ERROR) {
        $self->_log_error("command log failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'command log failed' );
    }

    return _idempotency_guard_result( $guarded, $input );
}

sub _command_guard ( $self, $input, $command_key ) {
    return $self->command_idempotency->run(
        {
            actor_id        => $input->{input}{author_user_id},
            command_id      => $command_key,
            command_type    => $input->{command_type},
            idempotency_key => $command_key,
            request         => $input->{request},
        },
        $input->{run},
        $input->{response},
    );
}

sub _idempotency_guard_result ( $guarded, $input ) {
    if ( $guarded->{invalid} ) {
        return _missing_command_id_result( $input->{input} );
    }
    if ( $guarded->{conflict} || $guarded->{in_progress} ) {
        return _result( status => 'conflict', error => $guarded->{error} );
    }
    if ( $guarded->{replayed} ) {
        return $input->{replay}->( $guarded->{response} );
    }

    return $guarded->{result};
}

sub _store_thread ( $self, $command ) {
    my $stored = eval { return $self->thread_store->create_thread($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("thread create failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'thread store failed' );
    }

    return _stored_result( $stored, 'thread store failed' );
}

sub _store_post ( $self, $command ) {
    my $stored = eval { return $self->post_store->create_post($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("reply create failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'post store failed' );
    }

    return _post_store_answer($stored);
}

sub _post_store_answer ($stored) {
    return _store_answer( $stored, 'post store failed' );
}

sub _thread_store_answer ($stored) {
    return _store_answer( $stored, 'thread store failed' );
}

# A store checks again, under its row locks, what the workflow checked before
# the transaction, because a moderator may have locked or hidden the thread or
# the post since, or the author deleted one. Its refusal is an answer, not a
# failure: the status the first check gives, recorded with the command and
# replayed with it.
sub _store_answer ( $stored, $fallback_error ) {
    my $refusal = _stored_refusal($stored);

    # exists first: reading an absent key of a constant hash dies.
    if ( exists $STORE_REFUSAL_STATUS{$refusal} ) {
        return _result(
            status => $STORE_REFUSAL_STATUS{$refusal},
            error  => $refusal
        );
    }

    return _stored_result( $stored, $fallback_error );
}

sub _stored_refusal ($stored) {
    return q{} if ref $stored ne 'HASH';
    return q{} if $stored->{ok};

    return $stored->{error} || q{};
}

sub _store_edit_post ( $self, $command ) {
    my $stored = eval { return $self->post_store->edit_post($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("post edit failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'post store failed' );
    }

    return _post_store_answer($stored);
}

sub _store_delete_post ( $self, $command ) {
    my $stored = eval { return $self->post_store->delete_post($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("post delete failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'post store failed' );
    }

    return _post_store_answer($stored);
}

sub _store_restore_post ( $self, $command ) {
    my $stored = eval { return $self->post_store->restore_post($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("post restore failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'post store failed' );
    }

    return _post_store_answer($stored);
}

sub _store_edit_thread ( $self, $command ) {
    my $stored = eval { return $self->thread_store->edit_thread($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("thread edit failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'thread store failed' );
    }

    return _thread_store_answer($stored);
}

sub _store_delete_thread ( $self, $command ) {
    my $stored = eval { return $self->thread_store->delete_thread($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("thread delete failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'thread store failed' );
    }

    return _thread_store_answer($stored);
}

sub _store_restore_thread ( $self, $command ) {
    my $stored = eval { return $self->thread_store->restore_thread($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("thread restore failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'thread store failed' );
    }

    return _thread_store_answer($stored);
}

sub _store_move_thread ( $self, $command ) {
    my $stored = eval { return $self->thread_store->move_thread($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("thread move failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'thread store failed' );
    }

    return _thread_store_answer($stored);
}

sub _record_post_mentions ( $self, $stored, $command ) {
    my $post_id  = _column( $stored->{post}, 'post_id' );
    my $actor_id = _column( $stored->{post}, 'author_user_id' )
      || $command->{post}{author_user_id};

    my $result = eval {
        return $self->mention_store->record_for_source(
            {
                source_type  => 'post',
                source_id    => $post_id,
                actor_id     => $actor_id,
                body_source  => $command->{body}{body_source},
                max_mentions => 10,
                thread_id    => $command->{post}{thread_id},
            }
        );
    };

    if ($EVAL_ERROR) {
        $self->_log_warning("mention recording degraded: $EVAL_ERROR");
        my $undefined;
        return $undefined;
    }

    return $result;
}

# ADR 0102: the effective visibility a new thread or reply may not exceed,
# from the columns of the category or thread it goes in. No category (the
# composer rejects that) sets no floor.
sub _effective_visibility ( $row, @columns ) {
    my $undefined;
    return $undefined if !$row;

    return GPForum::Service::Forum::Visibility->effective(
        map { _column( $row, $_ ) } @columns );
}

sub _command_id ($input) {
    my $source     = $input || {};
    my $command_id = _trim( $source->{command_id} );
    return $command_id if length $command_id;

    return _trim( $source->{idempotency_key} );
}

sub _missing_command_id_result ($input) {
    return _result(
        status   => 'invalid',
        prepared => {
            errors => { command_id => 'command_id is required' },
            ok     => 0,
            values => { %{ $input || {} } },
        },
    );
}

sub _body_hash ($body) {
    return sha256_hex( _trim($body) );
}

sub _thread_request ($input) {
    return {
        author_user_id => _trim( $input->{author_user_id} ),
        body_hash      => _body_hash( $input->{body_source} ),
        category_id    => _trim( $input->{category_id} ),
        title          => _trim( $input->{title} ),
        visibility     => _trim( $input->{visibility} ),
    };
}

sub _reply_request ($input) {
    return {
        author_user_id => _trim( $input->{author_user_id} ),
        body_hash      => _body_hash( $input->{body_source} ),
        thread_id      => _trim( $input->{thread_id} ),
        visibility     => _trim( $input->{visibility} ),
    };
}

sub _edit_request ($input) {
    return {
        author_user_id => _trim( $input->{author_user_id} ),
        body_hash      => _body_hash( $input->{body_source} ),
        post_id        => _trim( $input->{post_id} ),
    };
}

sub _delete_request ($input) {
    return {
        author_user_id => _trim( $input->{author_user_id} ),
        post_id        => _trim( $input->{post_id} ),
    };
}

sub _thread_edit_request ($input) {
    return {
        author_user_id => _trim( $input->{author_user_id} ),
        thread_id      => _trim( $input->{thread_id} ),
        title          => _trim( $input->{title} ),
    };
}

sub _thread_delete_request ($input) {
    return {
        author_user_id => _trim( $input->{author_user_id} ),
        thread_id      => _trim( $input->{thread_id} ),
    };
}

sub _thread_move_request ($input) {
    return {
        author_user_id => _trim( $input->{author_user_id} ),
        category_id    => _trim( $input->{category_id} ),
        thread_id      => _trim( $input->{thread_id} ),
    };
}

sub _thread_response_payload ($result) {
    my $response = _base_response_payload($result);
    if ( $result->{ok} ) {
        $response->{thread_id} =
          _column( $result->{stored}{thread}, 'thread_id' );
        $response->{post_id} = _column( $result->{stored}{post}, 'post_id' );
    }
    _include_validation_payload( $response, $result );

    return $response;
}

sub _reply_response_payload ($result) {
    my $response = _base_response_payload($result);
    if ( $result->{ok} ) {
        $response->{post_id} = _column( $result->{stored}{post}, 'post_id' );
        $response->{thread_id} =
          _column( $result->{stored}{post}, 'thread_id' );
    }
    _include_validation_payload( $response, $result );

    return $response;
}

sub _thread_edit_response_payload ($result) {
    my $response = _base_response_payload($result);
    if ( $result->{ok} ) {
        $response->{slug}  = _column( $result->{stored}{thread}, 'slug' );
        $response->{title} = _column( $result->{stored}{thread}, 'title' );
        $response->{thread_id} =
          _column( $result->{stored}{thread}, 'thread_id' );
    }
    _include_validation_payload( $response, $result );

    return $response;
}

sub _thread_result_from_response ($response) {
    return _result_from_response(
        $response,
        sub {
            return {
                ok     => 1,
                post   => { post_id   => $response->{post_id} },
                thread => { thread_id => $response->{thread_id} },
            };
        }
    );
}

sub _thread_edit_result_from_response ($response) {
    return _result_from_response(
        $response,
        sub {
            return {
                ok     => 1,
                thread => {
                    slug      => $response->{slug},
                    thread_id => $response->{thread_id},
                    title     => $response->{title},
                },
            };
        }
    );
}

sub _thread_delete_response_payload ($result) {
    my $response = _base_response_payload($result);
    if ( $result->{ok} ) {
        $response->{thread_id} =
          _column( $result->{stored}{thread}, 'thread_id' );
    }
    _include_validation_payload( $response, $result );

    return $response;
}

sub _thread_delete_result_from_response ($response) {
    return _result_from_response(
        $response,
        sub {
            return {
                ok     => 1,
                thread => { thread_id => $response->{thread_id} },
            };
        }
    );
}

sub _thread_move_response_payload ($result) {
    my $response = _base_response_payload($result);
    if ( $result->{ok} ) {
        $response->{category_id} =
          _column( $result->{stored}{thread}, 'category_id' );
        $response->{thread_id} =
          _column( $result->{stored}{thread}, 'thread_id' );
    }
    _include_validation_payload( $response, $result );

    return $response;
}

sub _thread_move_result_from_response ($response) {
    return _result_from_response(
        $response,
        sub {
            return {
                ok     => 1,
                thread => {
                    category_id => $response->{category_id},
                    thread_id   => $response->{thread_id},
                },
            };
        }
    );
}

sub _reply_result_from_response ($response) {
    return _result_from_response(
        $response,
        sub {
            return {
                ok   => 1,
                post => {
                    post_id   => $response->{post_id},
                    thread_id => $response->{thread_id},
                },
            };
        }
    );
}

sub _result_from_response ( $response, $stored_builder ) {
    my $prepared = _prepared_from_response($response);
    my $stored   = $response->{ok} ? $stored_builder->() : undef;

    return _result(
        error      => $response->{error},
        idempotent => 1,
        prepared   => $prepared,
        status     => $response->{status} || 'failed',
        stored     => $stored,
    );
}

sub _base_response_payload ($result) {
    my $response = {
        ok     => $result->{ok} ? 1 : 0,
        status => $result->{status} || 'failed',
    };
    if ( defined $result->{error} && length $result->{error} ) {
        $response->{error} = $result->{error};
    }

    return $response;
}

sub _include_validation_payload ( $response, $result ) {
    return if ( $result->{status} || q{} ) ne 'invalid';

    $response->{errors} = $result->{prepared}{errors} || {};
    $response->{values} = $result->{prepared}{values} || {};

    return;
}

sub _prepared_from_response ($response) {
    return
      if ( $response->{status} || q{} ) ne 'invalid';

    return {
        errors => $response->{errors} || {},
        ok     => 0,
        values => $response->{values} || {},
    };
}

sub _stored_result ( $stored, $fallback_error ) {
    return _result(
        status => 'failed',
        error  => $fallback_error,
        stored => $stored,
    ) if ref $stored ne 'HASH' || !$stored->{ok};

    return _result(
        status => 'ok',
        stored => $stored,
    );
}

sub _result (%input) {
    my $result = {
        error    => $input{error},
        ok       => ( $input{status} || q{} ) eq 'ok' ? 1 : 0,
        prepared => $input{prepared},
        status   => $input{status} || 'failed',
        stored   => $input{stored},
    };
    if ( $input{idempotent} ) {
        $result->{idempotent} = 1;
    }

    return $result;
}

sub _trim ($value) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

sub _log_error ( $self, $message ) {
    return if !$self->logger || !$self->logger->can('error');

    $self->logger->error($message);

    return;
}

sub _log_warning ( $self, $message ) {
    return if !$self->logger || !$self->logger->can('warn');

    $self->logger->warn($message);

    return;
}

# The author as a reader (ADR 0102): a write needs a category or thread they
# can read. Controllers pass the request's viewer; without one, anonymous --
# which reads public content only, so a write never widens access.
sub _viewer ($input) {
    return $input->{viewer} || GPForum::Service::Forum::Viewer->anonymous;
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::PostingWorkflow - Create, edit, move, delete and restore threads and posts, once per command id.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $workflow = GPForum::Service::Forum::PostingWorkflow->new(
        category_reader      => $category_reader,
        command_idempotency  => $command_idempotency,
        logger               => $app->log,
        mention_store        => $mention_store,
        post_composer        => $post_composer,
        post_reader          => $post_reader,
        post_store           => $post_store,
        thread_composer      => $thread_composer,
        thread_detail_reader => $thread_detail_reader,
        thread_store         => $thread_store,
    );

    my $result = $workflow->create_thread(
        {
            author_user_id => $user_id,
            body_source    => $markdown,
            category_id    => $category_id,
            command_id     => $command_id,
            title          => $title,
            viewer         => $viewer,
        }
    );
    if ( $result->{ok} ) {
        my $thread = $result->{stored}{thread};  # a Thread row
    }
    elsif ( $result->{status} eq 'invalid' ) {
        # $result->{prepared}{errors}, $result->{prepared}{values}
    }

    $workflow->create_reply(
        {
            author_user_id => $user_id,
            body_source    => $markdown,
            command_id     => $reply_command_id,
            thread_id      => $thread_id,
            viewer         => $viewer,
        }
    );

=head1 DESCRIPTION

The write side of the forum for its controllers: a new thread, a reply, and
an author's title edit, move, delete and restore of a thread, and edit,
delete and restore of a post. Each method checks the request, has a composer
validate it and build the command where there is something to validate,
hands the command to the store, and answers with one result shape.

The author acts as a reader (ADR 0102): the category and the thread are
read through the category reader and the thread detail reader as the
request's C<viewer>, or as an anonymous reader when there is none, so a
write never reaches what its author cannot read, and what they cannot read
is answered as not found. Only the author of a thread or a post may change
it, and not while it is hidden or its thread is locked. A new thread or reply
may not ask for a visibility broader than the effective visibility of the
category or thread it goes in, which the composer gets as its floor.

The store checks again, under its row locks, what the workflow checked
before the transaction, because a moderator may have locked or hidden the
thread or the post since, or the author deleted one in another tab. Its
refusal is an answer, not a failure: C<thread not found> and
C<post not found> become C<not_found>, and C<thread is locked> and
C<post is hidden> become C<forbidden>, the status the workflow's own check
gives for the same words.

Every method needs a command id. With a C<command_idempotency>
(L<GPForum::Service::Operations::CommandIdempotency>), a command runs once
per id: the request (the author and the trimmed fields each entry names,
the body as a SHA-256 hash of the trimmed source, but not the C<viewer> or
an C<edit_reason>) and the response are kept in the command log, a repeat of
the same request gets the response back without running anything, and a
different request under the same id is refused as a conflict. A C<failed>
result is not kept, so the same id can be tried again. Without a
C<command_idempotency>, every call runs.

After a new thread, a reply or a post edit is stored, the mentions in its
body are recorded through the mention store, at most ten; a failure there is
logged as a warning and does not fail the write.

=head1 SUBROUTINES/METHODS

Every method below takes one hash reference with C<command_id> (or
C<idempotency_key> when C<command_id> is empty; both are trimmed),
C<author_user_id>, the acting user, and an optional C<viewer>, a
L<GPForum::Service::Forum::Viewer> (anonymous when absent), plus the fields
named in its entry. It returns a hash reference:

    {
        ok       => 1 or 0,     # 1 only when status is 'ok'
        status   => $status,    # ok, invalid, not_found, forbidden,
                                # conflict or failed
        error    => $message,   # why, for every status but ok and invalid
        prepared => $prepared,  # the composer's answer, if one ran, on ok
                                # and invalid
        stored   => $stored,    # the store's answer, on ok
    }

A store's refusal or death is answered without C<prepared> or C<stored>;
only a C<failed> for a store answer that is neither a success nor a known
refusal carries that answer in C<stored>.

Every method also answers:

=over 4

=item * C<invalid>, with
C<< prepared => { ok => 0, errors => { command_id => 'command_id is required' }, values => { %input } } >>,
when the command id is empty;

=item * C<conflict>, with the command log's message, when the id was used
for another request or that command is still running;

=item * C<failed> with C<command log failed> when the command log fails, or
when anything the command runs dies (with a C<command_idempotency> only);

=item * C<failed> with C<thread store failed> or C<post store failed> when
the store dies or gives an answer that is neither a success nor one of the
refusals above;

=item * on a replay, the stored response as a result with C<< idempotent => 1 >>,
C<prepared> rebuilt for an C<invalid> answer, and C<stored> rebuilt from the
ids kept in the response, as each entry says.

=back

=head2 new

Mojo::Base constructor. The collaborators are attributes without defaults:
C<category_reader> (L<GPForum::Service::Forum::CategoryReader>),
C<thread_detail_reader> (L<GPForum::Service::Forum::ThreadDetailReader>),
C<post_reader> (L<GPForum::Service::Forum::PostReader>), C<thread_composer>
(L<GPForum::Service::Forum::ThreadComposer>), C<post_composer>
(L<GPForum::Service::Forum::PostComposer>), C<thread_store>
(L<GPForum::Service::Forum::ThreadStore>), C<post_store>
(L<GPForum::Service::Forum::PostStore>) and C<mention_store>
(L<GPForum::Service::Community::MentionStore>). C<command_idempotency> and
C<logger> (anything with C<error> and C<warn>, such as L<Mojo::Log>) are
optional. A method uses only the collaborators its path calls.

=head2 create_thread

Takes C<category_id>, C<title>, C<body_source> and an optional
C<visibility>. Returns C<not_found> (C<category not found>) when a category
id is given that the viewer cannot read, and C<invalid> with the composer's
answer when L<GPForum::Service::Forum::ThreadComposer/prepare> rejects the
input (an empty category id among the reasons). Otherwise stores the thread
with L<GPForum::Service::Forum::ThreadStore/create_thread>, records the
mentions in the opening post, and returns C<ok> with C<prepared> (holding
the command) and C<stored>, the store's answer (C<thread>, C<post> and
C<skipped>). Command type C<thread.create>; a replay's C<stored> is
C<< { ok => 1, thread => { thread_id }, post => { post_id } } >>.

=head2 create_reply

Takes C<thread_id>, C<body_source> and an optional C<visibility>. Returns
C<not_found> (C<thread not found>) when the viewer cannot read the thread,
C<forbidden> (C<thread is locked>) when it is locked, and C<invalid> when
L<GPForum::Service::Forum::PostComposer/prepare> rejects the input.
Otherwise stores the post, at the thread's next position, with
L<GPForum::Service::Forum::PostStore/create_post>, records its mentions, and
returns C<ok> with C<prepared> and C<stored>, the post store's answer; a
refusal of the post store is answered as described above. Command type
C<reply.create>; a replay's C<stored> is
C<< { ok => 1, post => { post_id, thread_id } } >>.

=head2 edit_thread

Takes C<thread_id> and C<title>. Returns C<not_found> (C<thread not found>)
when the viewer cannot read the thread or it is deleted; C<forbidden> when
the requester is not its author (C<not the thread author>), its moderation
state is C<hidden> (C<thread is hidden>) or it is locked
(C<thread is locked>); and C<invalid> when
L<GPForum::Service::Forum::ThreadComposer/prepare_title> rejects the title.
Otherwise stores the new title and slug with
L<GPForum::Service::Forum::ThreadStore/edit_thread> and returns C<ok> with
C<prepared> and C<stored> (C<thread>, and C<skipped> when nothing changed).
Command type C<thread.edit>; a replay's C<stored> is
C<< { ok => 1, thread => { thread_id, title, slug } } >>.

=head2 move_thread

Takes C<thread_id> and C<category_id>, the target. Gives the C<not_found>
and C<forbidden> answers of L</edit_thread>, so only the thread's author may
move it; then C<not_found> (C<category not found>) when a target id is given
that the viewer cannot read, and C<invalid> when
L<GPForum::Service::Forum::ThreadComposer/prepare_move> rejects the input
(an empty target among the reasons). Otherwise moves the thread with
L<GPForum::Service::Forum::ThreadStore/move_thread> and returns C<ok> with
C<prepared> and C<stored> (C<thread>, and C<skipped> when it was already
there). Command type C<thread.move>; a replay's C<stored> is
C<< { ok => 1, thread => { thread_id, category_id } } >>.

=head2 delete_thread

Takes C<thread_id>. Gives the C<not_found> and C<forbidden> answers of
L</edit_thread>; there is nothing to validate, so no composer runs and
C<prepared> is undefined. Otherwise soft-deletes the thread with
L<GPForum::Service::Forum::ThreadStore/delete_thread>, the requester as
C<deleted_by>, and returns C<ok> with C<stored> (C<thread>). Command type
C<thread.delete>; a replay's C<stored> is
C<< { ok => 1, thread => { thread_id } } >>.

=head2 restore_thread

Takes C<thread_id>. Returns C<not_found> (C<thread not found>) unless the
viewer can read the thread and it is deleted (the thread detail reader shows
a deleted thread to its author only), then the C<forbidden> answers of
L</edit_thread>. Otherwise restores the thread with
L<GPForum::Service::Forum::ThreadStore/restore_thread>, the requester as
C<restored_by>, and returns C<ok> with C<stored> (C<thread>). Command type
C<thread.restore>; replayed as L</delete_thread> is.

=head2 edit_post

Takes C<post_id>, C<body_source> and an optional C<edit_reason>. Returns
C<not_found> with C<post not found> when the post is missing or deleted, and
with C<thread not found> when the viewer cannot read its thread; C<forbidden>
when the requester is not its author (C<not the post author>), the post is
hidden (C<post is hidden>: it has a C<hidden_at>, or its moderation state is
C<hidden>) or the thread is locked (C<thread is locked>); and C<invalid>
when L<GPForum::Service::Forum::PostComposer/prepare_revision> rejects the
input. Otherwise stores the new revision with
L<GPForum::Service::Forum::PostStore/edit_post>, records the mentions in the
new body, and returns C<ok> with C<prepared> and C<stored>, the post store's
answer. Command type C<post.edit>; a replay's C<stored> is
C<< { ok => 1, post => { post_id, thread_id } } >>.

=head2 delete_post

Takes C<post_id>. Gives the C<not_found> and C<forbidden> answers of
L</edit_post>; no composer runs. Otherwise soft-deletes the post with
L<GPForum::Service::Forum::PostStore/delete_post>, the requester as
C<deleted_by>, and returns C<ok> with C<stored>. Command type
C<post.delete>; replayed as L</edit_post> is.

=head2 restore_post

Takes C<post_id>. Returns C<not_found> with C<post not found> unless the
post is deleted, and with C<thread not found> when the viewer cannot read
its thread; then the C<forbidden> answers of L</edit_post>. Otherwise
restores the post with L<GPForum::Service::Forum::PostStore/restore_post>,
the requester as C<restored_by>, and returns C<ok> with C<stored>. Command
type C<post.restore>; replayed as L</edit_post> is.

=head1 DIAGNOSTICS

A store's or the command log's error is caught and logged through C<logger>
at error level (C<thread create failed>, C<reply create failed>,
C<thread edit failed>, C<thread move failed>, C<thread delete failed>,
C<thread restore failed>, C<post edit failed>, C<post delete failed>,
C<post restore failed> or C<command log failed>, followed by the error), and
the result is C<failed>. A mention store error is logged at warning level as
C<mention recording degraded>. Without a C<command_idempotency>, an error in
a reader or a composer, an unset one included, dies out of the method; with
one, it is caught as C<command log failed>. Nothing is logged without a
C<logger>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Forum::Viewer>, L<GPForum::Service::Forum::Visibility>,
L<GPForum::Infrastructure::Row>, L<Digest::SHA>, L<English>, L<Const::Fast>,
L<Mojo::Base>, and the collaborators listed under L</new>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A replay rebuilds C<stored> from the response kept in the command log, so it
holds only the ids (and, for a title edit or a move, the new title and slug
or category), not the rows a first run returns.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
