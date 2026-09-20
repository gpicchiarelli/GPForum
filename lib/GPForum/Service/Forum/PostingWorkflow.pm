package GPForum::Service::Forum::PostingWorkflow;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use English     qw(-no_match_vars);
use Mojo::Base -base;

our $VERSION = '0.001';

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

sub _create_thread_once {
    my ( $self, $input ) = @_;

    my $command_id  = _command_id($input);
    my $category_id = _trim( $input->{category_id} );
    return _result( status => 'not_found', error => 'category not found' )
      if length $category_id
      && !$self->category_reader->find_category($category_id);

    my $prepared = $self->thread_composer->prepare(
        {
            category_id     => $category_id,
            author_user_id  => $input->{author_user_id},
            title           => $input->{title},
            body_source     => $input->{body_source},
            body_hash       => _body_hash( $input->{body_source} ),
            visibility      => $input->{visibility},
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

sub _create_reply_once {
    my ( $self, $input ) = @_;

    my $command_id = _command_id($input);
    my $thread =
      $self->thread_detail_reader->find_thread( $input->{thread_id} );
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
            visibility        => _reply_visibility( $input, $thread ),
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

sub _edit_thread_once {
    my ( $self, $input ) = @_;

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

sub _move_thread_once {
    my ( $self, $input ) = @_;

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

sub _thread_move_blocked {
    my ( $self, $input ) = @_;

    return $self->_thread_edit_blocked($input)
      || $self->_missing_move_category($input);
}

sub _missing_move_category {
    my ( $self, $input ) = @_;

    my $category_id = _trim( $input->{category_id} );
    if ( !length $category_id ) {
        return;
    }
    if ( !$self->category_reader->find_category($category_id) ) {
        return _result( status => 'not_found', error => 'category not found' );
    }

    return;
}

sub _prepare_move {
    my ( $self, $input ) = @_;

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

sub _delete_thread_once {
    my ( $self, $input ) = @_;

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

sub _restore_thread_once {
    my ( $self, $input ) = @_;

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

sub _thread_delete_command {
    my ( $self, $input ) = @_;

    my $thread =
      $self->thread_detail_reader->find_thread( $input->{thread_id} );

    return {
        idempotency_key => _command_id($input),
        thread          => {
            category_id => _column( $thread, 'category_id' ),
            deleted_by  => $input->{author_user_id},
            thread_id   => $input->{thread_id},
        },
    };
}

sub _thread_restore_command {
    my ( $self, $input ) = @_;

    my $thread =
      $self->thread_detail_reader->find_thread_row( $input->{thread_id} );

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

sub _prepare_title {
    my ( $self, $input ) = @_;

    return $self->thread_composer->prepare_title(
        {
            editor_user_id  => $input->{author_user_id},
            idempotency_key => _command_id($input),
            thread_id       => $input->{thread_id},
            title           => $input->{title},
        }
    );
}

sub _thread_edit_blocked {
    my ( $self, $input ) = @_;

    my $thread =
      $self->thread_detail_reader->find_thread( $input->{thread_id} );

    return _missing_edit_thread($thread)
      || _forbidden_thread_edit( $thread, $input );
}

sub _restore_thread_blocked {
    my ( $self, $input ) = @_;

    my $thread =
      $self->thread_detail_reader->find_thread_row( $input->{thread_id} );

    return _missing_restore_thread($thread)
      || _forbidden_thread_edit( $thread, $input );
}

sub _missing_edit_thread {
    my ($thread) = @_;

    if ( !_live_thread($thread) ) {
        return _result( status => 'not_found', error => 'thread not found' );
    }

    return;
}

sub _missing_restore_thread {
    my ($thread) = @_;

    if ( !_deleted_thread($thread) ) {
        return _result( status => 'not_found', error => 'thread not found' );
    }

    return;
}

sub _live_thread {
    my ($thread) = @_;

    if ( !$thread ) {
        return 0;
    }
    if ( defined _column( $thread, 'deleted_at' ) ) {
        return 0;
    }

    return 1;
}

sub _deleted_thread {
    my ($thread) = @_;

    if ( !$thread ) {
        return 0;
    }
    if ( defined _column( $thread, 'deleted_at' ) ) {
        return 1;
    }

    return 0;
}

sub _forbidden_thread_edit {
    my ( $thread, $input ) = @_;

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

    return;
}

sub _same_thread_author {
    my ( $thread, $input ) = @_;

    my $author = _column( $thread, 'author_user_id' ) || q{};

    return $author eq _trim( $input->{author_user_id} ) ? 1 : 0;
}

sub _hidden_thread {
    my ($thread) = @_;

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

sub _edit_post_once {
    my ( $self, $input ) = @_;

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

sub _delete_post_once {
    my ( $self, $input ) = @_;

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

sub _restore_post_once {
    my ( $self, $input ) = @_;

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

sub _delete_command {
    my ( $self, $input ) = @_;

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

sub _restore_command {
    my ( $self, $input ) = @_;

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

sub _prepare_revision {
    my ( $self, $input ) = @_;

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

sub _edit_blocked {
    my ( $self, $input ) = @_;

    my $post   = $self->post_reader->find_post( $input->{post_id} );
    my $thread = $self->_thread_for_post($post);

    return _missing_edit_target( $post, $thread )
      || _forbidden_edit( $post, $input, $thread );
}

sub _restore_blocked {
    my ( $self, $input ) = @_;

    my $post   = $self->post_reader->find_post( $input->{post_id} );
    my $thread = $self->_thread_for_post($post);

    return _missing_restore_target( $post, $thread )
      || _forbidden_edit( $post, $input, $thread );
}

sub _thread_for_post {
    my ( $self, $post ) = @_;

    return if !$post;

    return $self->thread_detail_reader->find_thread(
        _column( $post, 'thread_id' ) );
}

sub _missing_edit_target {
    my ( $post, $thread ) = @_;

    return _result( status => 'not_found', error => 'post not found' )
      if !_live_post($post);
    return _result( status => 'not_found', error => 'thread not found' )
      if !$thread;

    return;
}

sub _missing_restore_target {
    my ( $post, $thread ) = @_;

    return _result( status => 'not_found', error => 'post not found' )
      if !_deleted_post($post);
    return _result( status => 'not_found', error => 'thread not found' )
      if !$thread;

    return;
}

sub _live_post {
    my ($post) = @_;

    return 0 if !$post;
    return 0 if defined _column( $post, 'deleted_at' );

    return 1;
}

sub _deleted_post {
    my ($post) = @_;

    return 0 if !$post;

    return defined _column( $post, 'deleted_at' ) ? 1 : 0;
}

sub _forbidden_edit {
    my ( $post, $input, $thread ) = @_;

    return _result( status => 'forbidden', error => 'not the post author' )
      if !_same_author( $post, $input );
    return _result( status => 'forbidden', error => 'post is hidden' )
      if _hidden_post($post);
    return _result( status => 'forbidden', error => 'thread is locked' )
      if defined _column( $thread, 'locked_at' );

    return;
}

sub _same_author {
    my ( $post, $input ) = @_;

    my $author = _column( $post, 'author_user_id' ) || q{};

    return $author eq _trim( $input->{author_user_id} ) ? 1 : 0;
}

sub _hidden_post {
    my ($post) = @_;

    return 1 if defined _column( $post, 'hidden_at' );

    my $state = _column( $post, 'moderation_state' ) || q{};

    return $state eq 'hidden' ? 1 : 0;
}

sub _run_idempotent_command {
    my ( $self, $input ) = @_;

    my $command_key = _command_id( $input->{input} );
    if ( !length $command_key ) {
        return _missing_command_id_result( $input->{input} );
    }

    if ( !$self->command_idempotency ) {
        return $input->{run}->();
    }

    return $self->_guarded_command( $input, $command_key );
}

sub _guarded_command {
    my ( $self, $input, $command_key ) = @_;

    my $guarded =
      eval { return $self->_command_guard( $input, $command_key ); };
    if ($EVAL_ERROR) {
        $self->_log_error("command log failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'command log failed' );
    }

    return _idempotency_guard_result( $guarded, $input );
}

sub _command_guard {
    my ( $self, $input, $command_key ) = @_;

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

sub _idempotency_guard_result {
    my ( $guarded, $input ) = @_;

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

sub _store_thread {
    my ( $self, $command ) = @_;

    my $stored = eval { return $self->thread_store->create_thread($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("thread create failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'thread store failed' );
    }

    return _stored_result( $stored, 'thread store failed' );
}

sub _store_post {
    my ( $self, $command ) = @_;

    my $stored = eval { return $self->post_store->create_post($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("reply create failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'post store failed' );
    }

    return _stored_result( $stored, 'post store failed' );
}

sub _store_edit_post {
    my ( $self, $command ) = @_;

    my $stored = eval { return $self->post_store->edit_post($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("post edit failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'post store failed' );
    }

    return _edit_stored_result($stored);
}

sub _store_delete_post {
    my ( $self, $command ) = @_;

    my $stored = eval { return $self->post_store->delete_post($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("post delete failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'post store failed' );
    }

    return _edit_stored_result($stored);
}

sub _store_restore_post {
    my ( $self, $command ) = @_;

    my $stored = eval { return $self->post_store->restore_post($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("post restore failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'post store failed' );
    }

    return _edit_stored_result($stored);
}

sub _store_edit_thread {
    my ( $self, $command ) = @_;

    my $stored = eval { return $self->thread_store->edit_thread($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("thread edit failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'thread store failed' );
    }

    return _edit_thread_stored_result($stored);
}

sub _store_delete_thread {
    my ( $self, $command ) = @_;

    my $stored = eval { return $self->thread_store->delete_thread($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("thread delete failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'thread store failed' );
    }

    return _edit_thread_stored_result($stored);
}

sub _store_restore_thread {
    my ( $self, $command ) = @_;

    my $stored = eval { return $self->thread_store->restore_thread($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("thread restore failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'thread store failed' );
    }

    return _edit_thread_stored_result($stored);
}

sub _store_move_thread {
    my ( $self, $command ) = @_;

    my $stored = eval { return $self->thread_store->move_thread($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("thread move failed: $EVAL_ERROR");
        return _result( status => 'failed', error => 'thread store failed' );
    }

    return _edit_thread_stored_result($stored);
}

sub _edit_thread_stored_result {
    my ($stored) = @_;

    if ( _missing_stored_thread($stored) ) {
        return _result( status => 'not_found', error => 'thread not found' );
    }

    return _stored_result( $stored, 'thread store failed' );
}

sub _missing_stored_thread {
    my ($stored) = @_;

    return 0 if ref $stored ne 'HASH';
    return 0 if $stored->{ok};
    return 1 if ( $stored->{error} || q{} ) eq 'thread not found';

    return 0;
}

sub _edit_stored_result {
    my ($stored) = @_;

    if ( _missing_stored_post($stored) ) {
        return _result( status => 'not_found', error => 'post not found' );
    }

    return _stored_result( $stored, 'post store failed' );
}

sub _missing_stored_post {
    my ($stored) = @_;

    return 0 if ref $stored ne 'HASH';
    return 0 if $stored->{ok};
    return 1 if ( $stored->{error} || q{} ) eq 'post not found';

    return 0;
}

sub _record_post_mentions {
    my ( $self, $stored, $command ) = @_;

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
        return;
    }

    return $result;
}

sub _reply_visibility {
    my ( $input, $thread ) = @_;

    return $input->{visibility}
      if defined $input->{visibility} && length $input->{visibility};

    return _column( $thread, 'visibility' );
}

sub _command_id {
    my ($input) = @_;

    my $source     = $input || {};
    my $command_id = _trim( $source->{command_id} );
    return $command_id if length $command_id;

    return _trim( $source->{idempotency_key} );
}

sub _missing_command_id_result {
    my ($input) = @_;

    return _result(
        status   => 'invalid',
        prepared => {
            errors => { command_id => 'command_id is required' },
            ok     => 0,
            values => { %{ $input || {} } },
        },
    );
}

sub _body_hash {
    my ($body) = @_;

    return sha256_hex( _trim($body) );
}

sub _thread_request {
    my ($input) = @_;

    return {
        author_user_id => _trim( $input->{author_user_id} ),
        body_hash      => _body_hash( $input->{body_source} ),
        category_id    => _trim( $input->{category_id} ),
        title          => _trim( $input->{title} ),
        visibility     => _trim( $input->{visibility} ),
    };
}

sub _reply_request {
    my ($input) = @_;

    return {
        author_user_id => _trim( $input->{author_user_id} ),
        body_hash      => _body_hash( $input->{body_source} ),
        thread_id      => _trim( $input->{thread_id} ),
        visibility     => _trim( $input->{visibility} ),
    };
}

sub _edit_request {
    my ($input) = @_;

    return {
        author_user_id => _trim( $input->{author_user_id} ),
        body_hash      => _body_hash( $input->{body_source} ),
        post_id        => _trim( $input->{post_id} ),
    };
}

sub _delete_request {
    my ($input) = @_;

    return {
        author_user_id => _trim( $input->{author_user_id} ),
        post_id        => _trim( $input->{post_id} ),
    };
}

sub _thread_edit_request {
    my ($input) = @_;

    return {
        author_user_id => _trim( $input->{author_user_id} ),
        thread_id      => _trim( $input->{thread_id} ),
        title          => _trim( $input->{title} ),
    };
}

sub _thread_delete_request {
    my ($input) = @_;

    return {
        author_user_id => _trim( $input->{author_user_id} ),
        thread_id      => _trim( $input->{thread_id} ),
    };
}

sub _thread_move_request {
    my ($input) = @_;

    return {
        author_user_id => _trim( $input->{author_user_id} ),
        category_id    => _trim( $input->{category_id} ),
        thread_id      => _trim( $input->{thread_id} ),
    };
}

sub _thread_response_payload {
    my ($result) = @_;

    my $response = _base_response_payload($result);
    if ( $result->{ok} ) {
        $response->{thread_id} =
          _column( $result->{stored}{thread}, 'thread_id' );
        $response->{post_id} = _column( $result->{stored}{post}, 'post_id' );
    }
    _include_validation_payload( $response, $result );

    return $response;
}

sub _reply_response_payload {
    my ($result) = @_;

    my $response = _base_response_payload($result);
    if ( $result->{ok} ) {
        $response->{post_id} = _column( $result->{stored}{post}, 'post_id' );
        $response->{thread_id} =
          _column( $result->{stored}{post}, 'thread_id' );
    }
    _include_validation_payload( $response, $result );

    return $response;
}

sub _thread_edit_response_payload {
    my ($result) = @_;

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

sub _thread_result_from_response {
    my ($response) = @_;

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

sub _thread_edit_result_from_response {
    my ($response) = @_;

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

sub _thread_delete_response_payload {
    my ($result) = @_;

    my $response = _base_response_payload($result);
    if ( $result->{ok} ) {
        $response->{thread_id} =
          _column( $result->{stored}{thread}, 'thread_id' );
    }
    _include_validation_payload( $response, $result );

    return $response;
}

sub _thread_delete_result_from_response {
    my ($response) = @_;

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

sub _thread_move_response_payload {
    my ($result) = @_;

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

sub _thread_move_result_from_response {
    my ($response) = @_;

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

sub _reply_result_from_response {
    my ($response) = @_;

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

sub _result_from_response {
    my ( $response, $stored_builder ) = @_;

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

sub _base_response_payload {
    my ($result) = @_;

    my $response = {
        ok     => $result->{ok} ? 1 : 0,
        status => $result->{status} || 'failed',
    };
    if ( defined $result->{error} && length $result->{error} ) {
        $response->{error} = $result->{error};
    }

    return $response;
}

sub _include_validation_payload {
    my ( $response, $result ) = @_;

    return if ( $result->{status} || q{} ) ne 'invalid';

    $response->{errors} = $result->{prepared}{errors} || {};
    $response->{values} = $result->{prepared}{values} || {};

    return;
}

sub _prepared_from_response {
    my ($response) = @_;

    return
      if ( $response->{status} || q{} ) ne 'invalid';

    return {
        errors => $response->{errors} || {},
        ok     => 0,
        values => $response->{values} || {},
    };
}

sub _stored_result {
    my ( $stored, $fallback_error ) = @_;

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

sub _result {
    my (%input) = @_;

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

sub _trim {
    my ($value) = @_;

    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub _column {
    my ( $row, $name ) = @_;

    return                         if !$row;
    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row->can('get_column');
    return;
}

sub _log_error {
    my ( $self, $message ) = @_;

    return if !$self->logger || !$self->logger->can('error');

    $self->logger->error($message);

    return;
}

sub _log_warning {
    my ( $self, $message ) = @_;

    return if !$self->logger || !$self->logger->can('warn');

    $self->logger->warn($message);

    return;
}

1;
