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

sub _run_idempotent_command {
    my ( $self, $input ) = @_;

    my $command_key = _command_id( $input->{input} );
    return _missing_command_id_result( $input->{input} )
      if !length $command_key;

    if ( !$self->command_idempotency ) {
        return $input->{run}->();
    }

    my $guarded = $self->command_idempotency->run(
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

    return _idempotency_guard_result( $guarded, $input );
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
