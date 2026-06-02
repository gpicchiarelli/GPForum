package GPForum::Service::Forum::ThreadStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $SCHEMA_VERSION   => 1;
const my $THREAD_AGGREGATE => 'thread';
const my $POST_AGGREGATE   => 'post';

has schema     => undef;
has id_service => sub { return GPForum::Service::Id->new; };
has recorder   => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};

sub create_thread {
    my ( $self, $command ) = @_;

    my $result = $self->schema->txn_do(
        sub {
            return $self->_insert_thread($command);
        }
    );

    return { ok => 1, thread => $result->{thread}, post => $result->{post} };
}

sub _insert_thread {
    my ( $self, $command ) = @_;

    my $thread =
      $self->schema->resultset('Thread')->create( $command->{thread} );
    my $post = $self->schema->resultset('Post')->create( $command->{post} );

    $self->schema->resultset('PostBody')->create( $command->{body} );
    $self->schema->resultset('PostRevision')->create( $command->{revision} );
    $self->schema->resultset('ThreadCounter')->create( $command->{counter} );

    my $correlation_id = $self->id_service->uuid;
    my $thread_event_id =
      $self->_record_thread_event( $command, $correlation_id );
    $self->_record_post_event( $command, $correlation_id, $thread_event_id );
    $self->_record_audit( $command, $correlation_id );

    return { thread => $thread, post => $post };
}

sub _record_thread_event {
    my ( $self, $command, $correlation_id ) = @_;

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

sub _record_post_event {
    my ( $self, $command, $correlation_id, $causation_id ) = @_;

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

sub _record_audit {
    my ( $self, $command, $correlation_id ) = @_;

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

sub _idempotency_key {
    my ( $command, $event_type, $aggregate_id ) = @_;

    if ( defined $command->{idempotency_key}
        && length $command->{idempotency_key} )
    {
        return join q{:}, 'command', $command->{idempotency_key}, $event_type;
    }

    return join q{:}, $event_type, $aggregate_id;
}

1;
