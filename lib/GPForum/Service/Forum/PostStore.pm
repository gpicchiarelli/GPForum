package GPForum::Service::Forum::PostStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $SCHEMA_VERSION => 1;
const my $POST_AGGREGATE => 'post';
const my $FIRST_POSITION => 1;

has schema     => undef;
has id_service => sub { return GPForum::Service::Id->new; };
has recorder   => sub {
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

    return { ok => 1, post => $result->{post} };
}

sub _insert_post {
    my ( $self, $input_command ) = @_;

    my $command = $self->_command_with_allocated_position($input_command);

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

sub _command_with_allocated_position {
    my ( $self, $command ) = @_;

    return $command if _valid_position( $command->{post}{position} );

    my $thread_id = $command->{post}{thread_id};
    $self->_lock_thread_for_position($thread_id);

    my %post = %{ $command->{post} };
    $post{position} = $self->_next_position($thread_id);

    return { %{$command}, post => \%post };
}

sub _lock_thread_for_position {
    my ( $self, $thread_id ) = @_;

    my $dbh = _schema_dbh( $self->schema );
    return if !$dbh;

    $dbh->selectrow_array(
        'SELECT thread_id FROM threads WHERE thread_id = ? FOR UPDATE',
        undef, $thread_id );

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
