package GPForum::Worker::Handler::SearchIndexing;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $THREAD_CREATED  => 'thread.created';
const my $THREAD_UPDATED  => 'thread.updated';
const my $POST_CREATED    => 'post.created';
const my $POST_UPDATED    => 'post.updated';
const my $POST_HIDDEN     => 'post.hidden';
const my $POST_RESTORED   => 'post.restored';
const my $THREAD_LOCKED   => 'thread.locked';
const my $THREAD_UNLOCKED => 'thread.unlocked';
const my $ACTION_REVERSED => 'moderation_action.reversed';

has sink    => undef;
has indexer => undef;

sub supports {
    my ( $self, $event ) = @_;

    return
         $event->{event_type} eq $THREAD_CREATED
      || $event->{event_type} eq $THREAD_UPDATED
      || $event->{event_type} eq $POST_CREATED
      || $event->{event_type} eq $POST_UPDATED
      || $event->{event_type} eq $POST_HIDDEN
      || $event->{event_type} eq $POST_RESTORED
      || $event->{event_type} eq $THREAD_LOCKED
      || $event->{event_type} eq $THREAD_UNLOCKED
      || $event->{event_type} eq $ACTION_REVERSED ? 1 : 0;
}

sub handle {
    my ( $self, $event ) = @_;

    my $task = {
        action      => _action_for($event),
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

    return $self->indexer->remove_post( $event->{aggregate_id} )
      if $event->{event_type} eq $POST_HIDDEN;

    return $self->_index_reversal($event)
      if $event->{event_type} eq $ACTION_REVERSED;

    return $self->indexer->index_thread( $event->{aggregate_id} )
      if $event->{aggregate_type} eq 'thread';

    return $self->indexer->index_post( $event->{aggregate_id} )
      if $event->{aggregate_type} eq 'post';

    return;
}

sub _index_reversal {
    my ( $self, $event ) = @_;

    my $payload     = $event->{domain_payload} || $event->{payload} || {};
    my $target_type = $payload->{target_type}  || $event->{aggregate_type};
    my $target_id   = $payload->{target_id};

    return if !$target_id;

    return $self->indexer->index_thread($target_id)
      if $target_type eq 'thread';

    return $self->indexer->index_post($target_id)
      if $target_type eq 'post';

    return;
}

sub _action_for {
    my ($event) = @_;

    return 'search.remove' if $event->{event_type} eq $POST_HIDDEN;

    return 'search.index';
}

1;
