package GPForum::Service::Forum::PostingWorkflow;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use English     qw(-no_match_vars);
use Mojo::Base -base;

our $VERSION = '0.001';

has category_reader      => undef;
has logger               => undef;
has mention_store        => undef;
has post_composer        => undef;
has post_position        => undef;
has post_store           => undef;
has thread_composer      => undef;
has thread_detail_reader => undef;
has thread_store         => undef;

sub create_thread {
    my ( $self, $input ) = @_;

    my $category_id = _trim( $input->{category_id} );
    return { ok => 0, status => 'not_found', error => 'category not found' }
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
            idempotency_key => $input->{idempotency_key},
        }
    );

    return { ok => 0, status => 'invalid', prepared => $prepared }
      if !$prepared->{ok};

    my $stored = $self->_store_thread( $prepared->{command} );
    return $stored if !$stored->{ok};

    $self->_record_post_mentions( $stored, $prepared->{command} );

    return { ok => 1, stored => $stored };
}

sub create_reply {
    my ( $self, $input ) = @_;

    my $thread =
      $self->thread_detail_reader->find_thread( $input->{thread_id} );
    return { ok => 0, status => 'not_found', error => 'thread not found' }
      if !$thread;
    return { ok => 0, status => 'forbidden', error => 'thread is locked' }
      if defined _column( $thread, 'locked_at' );

    my $prepared = $self->post_composer->prepare(
        {
            thread_id      => $input->{thread_id},
            author_user_id => $input->{author_user_id},
            position       =>
              $self->post_position->next_position( $input->{thread_id} ),
            body_source => $input->{body_source},
            body_hash   => _body_hash( $input->{body_source} ),
            visibility  => _reply_visibility( $input, $thread ),
        }
    );

    return { ok => 0, status => 'invalid', prepared => $prepared }
      if !$prepared->{ok};

    my $stored = $self->_store_post( $prepared->{command} );
    return $stored if !$stored->{ok};

    $self->_record_post_mentions( $stored, $prepared->{command} );

    return { ok => 1, stored => $stored };
}

sub _store_thread {
    my ( $self, $command ) = @_;

    my $stored = eval { return $self->thread_store->create_thread($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("thread create failed: $EVAL_ERROR");
        return { ok => 0, status => 'failed' };
    }

    return $stored;
}

sub _store_post {
    my ( $self, $command ) = @_;

    my $stored = eval { return $self->post_store->create_post($command); };
    if ($EVAL_ERROR) {
        $self->_log_error("reply create failed: $EVAL_ERROR");
        return { ok => 0, status => 'failed' };
    }

    return $stored;
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

sub _body_hash {
    my ($body) = @_;

    return sha256_hex( _trim($body) );
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
