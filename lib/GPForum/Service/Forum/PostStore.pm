package GPForum::Service::Forum::PostStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Id;
use GPForum::Service::Outbox::MessageBuilder;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;
const my $POST_AGGREGATE => 'post';

has schema         => undef;
has id_service     => sub { return GPForum::Service::Id->new; };
has outbox_builder => sub {
    my ($self) = @_;

    return GPForum::Service::Outbox::MessageBuilder->new(
        id_service => $self->id_service, );
};

sub create_post {
    my ( $self, $command ) = @_;

    my $result = $self->schema->txn_do(
        sub {
            return $self->_insert_post($command);
        }
    );

    return { ok => 1, post => $result->{post} };
}

sub _insert_post {
    my ( $self, $command ) = @_;

    my $post = $self->schema->resultset('Post')->create( $command->{post} );

    $self->schema->resultset('PostBody')->create( $command->{body} );
    $self->schema->resultset('PostRevision')->create( $command->{revision} );
    $self->schema->resultset('ThreadCounterShard')
      ->create( $command->{counter_shard} );

    my $correlation_id = $self->id_service->uuid;

    $self->_record_post_event( $command, $correlation_id );
    $self->_record_audit( $command, $correlation_id );

    return { post => $post };
}

sub _record_post_event {
    my ( $self, $command, $correlation_id ) = @_;

    my $event = {
        event_id          => $self->id_service->uuid,
        event_type        => 'post.created',
        schema_version    => $SCHEMA_VERSION,
        aggregate_type    => $POST_AGGREGATE,
        aggregate_id      => $command->{post}{post_id},
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $command->{post}{author_user_id},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   =>
          _idempotency_key( 'post.created', $command->{post}{post_id} ),
        payload => {
            post_id        => $command->{post}{post_id},
            thread_id      => $command->{post}{thread_id},
            author_user_id => $command->{post}{author_user_id},
            revision_id    => $command->{revision}{revision_id},
        },
        metadata => {},
    };

    $self->schema->resultset('EventLog')->create($event);
    $self->schema->resultset('OutboxMessage')
      ->create( $self->outbox_builder->for_event($event) );

    return;
}

sub _record_audit {
    my ( $self, $command, $correlation_id ) = @_;

    $self->schema->resultset('AuditLog')->create(
        {
            audit_id       => $self->id_service->uuid,
            action         => 'post.created',
            schema_version => $SCHEMA_VERSION,
            actor_id       => $command->{post}{author_user_id},
            target_type    => $POST_AGGREGATE,
            target_id      => $command->{post}{post_id},
            correlation_id => $correlation_id,
            metadata       => { thread_id => $command->{post}{thread_id} },
        }
    );

    return;
}

sub _idempotency_key {
    my ( $event_type, $aggregate_id ) = @_;

    return join q{:}, $event_type, $aggregate_id;
}

1;
