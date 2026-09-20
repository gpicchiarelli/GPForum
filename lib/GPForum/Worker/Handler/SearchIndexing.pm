package GPForum::Worker::Handler::SearchIndexing;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $THREAD_CREATED   => 'thread.created';
const my $THREAD_UPDATED   => 'thread.updated';
const my $THREAD_DELETED   => 'thread.deleted';
const my $THREAD_MOVED     => 'thread.moved';
const my $POST_CREATED     => 'post.created';
const my $POST_UPDATED     => 'post.updated';
const my $POST_DELETED     => 'post.deleted';
const my $POST_HIDDEN      => 'post.hidden';
const my $POST_RESTORED    => 'post.restored';
const my $POST_UNDELETED   => 'post.undeleted';
const my $THREAD_LOCKED    => 'thread.locked';
const my $THREAD_UNLOCKED  => 'thread.unlocked';
const my $THREAD_HIDDEN    => 'thread.hidden';
const my $THREAD_RESTORED  => 'thread.restored';
const my $THREAD_UNDELETED => 'thread.undeleted';
const my $ACTION_REVERSED  => 'moderation_action.reversed';

const my %SUPPORTED => (
    $ACTION_REVERSED  => 1,
    $POST_CREATED     => 1,
    $POST_DELETED     => 1,
    $POST_HIDDEN      => 1,
    $POST_RESTORED    => 1,
    $POST_UNDELETED   => 1,
    $POST_UPDATED     => 1,
    $THREAD_CREATED   => 1,
    $THREAD_DELETED   => 1,
    $THREAD_HIDDEN    => 1,
    $THREAD_LOCKED    => 1,
    $THREAD_MOVED     => 1,
    $THREAD_RESTORED  => 1,
    $THREAD_UNDELETED => 1,
    $THREAD_UNLOCKED  => 1,
    $THREAD_UPDATED   => 1,
);

const my %SEARCH_REMOVAL => (
    $POST_DELETED   => 1,
    $POST_HIDDEN    => 1,
    $THREAD_DELETED => 1,
    $THREAD_HIDDEN  => 1,
);

const my %THREAD_POST_REINDEX => (
    $THREAD_RESTORED  => 1,
    $THREAD_UNDELETED => 1,
);

has sink    => undef;
has indexer => undef;

sub supports {
    my ( undef, $event ) = @_;

    my $event_type = $event->{event_type};
    return 0 if !defined $event_type;
    return exists $SUPPORTED{$event_type} ? 1 : 0;
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

    if ( _is_search_removal($event) ) {
        return $self->_remove_indexed($event);
    }
    if ( $event->{event_type} eq $ACTION_REVERSED ) {
        return $self->_index_reversal($event);
    }

    return $self->_index_aggregate($event);
}

sub _index_aggregate {
    my ( $self, $event ) = @_;

    if ( ( $event->{aggregate_type} || q{} ) eq 'thread' ) {
        return $self->_index_thread_event($event);
    }
    if ( ( $event->{aggregate_type} || q{} ) eq 'post' ) {
        return $self->indexer->index_post( $event->{aggregate_id} );
    }

    return;
}

sub _index_thread_event {
    my ( $self, $event ) = @_;

    my $thread_id = $event->{aggregate_id};
    if ( _reindex_thread_posts($event) ) {
        return $self->_reindex_thread($thread_id);
    }

    return $self->indexer->index_thread($thread_id);
}

sub _reindex_thread {
    my ( $self, $thread_id ) = @_;

    my $result = $self->indexer->index_thread($thread_id);
    $result->{posts_indexed} = $self->indexer->index_thread_posts($thread_id);

    return $result;
}

sub _reindex_thread_posts {
    my ($event) = @_;

    my $event_type = $event->{event_type};
    if ( !defined $event_type ) {
        return 0;
    }

    return exists $THREAD_POST_REINDEX{$event_type} ? 1 : 0;
}

sub _remove_indexed {
    my ( $self, $event ) = @_;

    if ( ( $event->{aggregate_type} || q{} ) eq 'thread' ) {
        return $self->indexer->remove_thread( $event->{aggregate_id} );
    }

    return $self->indexer->remove_post( $event->{aggregate_id} );
}

sub _index_reversal {
    my ( $self, $event ) = @_;

    my $payload     = $event->{domain_payload} || $event->{payload} || {};
    my $target_type = $payload->{target_type}  || $event->{aggregate_type};
    my $target_id   = $payload->{target_id};

    return if !$target_id;

    if ( $target_type eq 'thread' ) {
        return $self->_reindex_thread($target_id);
    }
    if ( $target_type eq 'post' ) {
        return $self->indexer->index_post($target_id);
    }

    return;
}

sub _action_for {
    my ($event) = @_;

    if ( _is_search_removal($event) ) {
        return 'search.remove';
    }

    return 'search.index';
}

sub _is_search_removal {
    my ($event) = @_;

    my $event_type = $event->{event_type};
    if ( !defined $event_type ) {
        return 0;
    }

    return exists $SEARCH_REMOVAL{$event_type} ? 1 : 0;
}

1;
