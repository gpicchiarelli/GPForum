package GPForum::Worker::Handler::SearchIndexing;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $THREAD_CREATED => 'thread.created';
const my $POST_CREATED   => 'post.created';

has sink    => undef;
has indexer => undef;

sub supports {
    my ( $self, $event ) = @_;

    return $event->{event_type} eq $THREAD_CREATED
      || $event->{event_type} eq $POST_CREATED;
}

sub handle {
    my ( $self, $event ) = @_;

    my $task = {
        action      => 'search.index',
        entity_type => $event->{aggregate_type},
        entity_id   => $event->{aggregate_id},
        event_id    => $event->{event_id},
    };

    if ( $self->sink ) {
        $self->sink->capture($task);
    }

    if ( $self->indexer ) {
        $task->{indexed} = $self->_index_event($event);
    }

    return $task;
}

sub _index_event {
    my ( $self, $event ) = @_;

    return $self->indexer->index_thread( $event->{aggregate_id} )
      if $event->{aggregate_type} eq 'thread';

    return $self->indexer->index_post( $event->{aggregate_id} )
      if $event->{aggregate_type} eq 'post';

    return;
}

1;
