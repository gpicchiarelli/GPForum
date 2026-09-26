# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Worker::Handler::SearchIndexing;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::EventRecorder;

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
const my $REBUILD_STEP     => 'search.rebuild_requested';
const my $THREAD_POSTS     => 'search.thread_posts_requested';

const my %SUPPORTED => (
    $ACTION_REVERSED  => 1,
    $REBUILD_STEP     => 1,
    $THREAD_POSTS     => 1,
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

# A post document carries its thread's title and category (DocumentBuilder),
# so these re-derive the thread's posts as well as the thread: the first
# batch with the event, the rest one batch per search.thread_posts_requested
# message.
const my %THREAD_POST_REINDEX => (
    $THREAD_MOVED     => 1,
    $THREAD_RESTORED  => 1,
    $THREAD_UNDELETED => 1,
    $THREAD_UPDATED   => 1,
);

has sink    => undef;
has indexer => undef;

# The console's search rebuild: one batch per outbox message
# (Search::RebuildRun).
has rebuild_run => undef;

# Records the next batch of a thread's posts, in the database the documents
# are written to.
has recorder => sub ($self) {
    return GPForum::Infrastructure::EventRecorder->new(
        schema => $self->indexer->schema );
};

sub supports ( $, $event ) {
    my $event_type = $event->{event_type};
    return 0 if !defined $event_type;
    return exists $SUPPORTED{$event_type} ? 1 : 0;
}

sub handle ( $self, $event ) {
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

sub _index_event ( $self, $event ) {
    if ( $event->{event_type} eq $REBUILD_STEP ) {
        return $self->rebuild_run ? $self->rebuild_run->step($event) : undef;
    }
    if ( $event->{event_type} eq $THREAD_POSTS ) {
        my $payload = _payload($event);
        return $self->_index_thread_posts( $payload->{thread_id},
            $payload->{after}, $event );
    }
    if ( _is_search_removal($event) ) {
        return $self->_remove_indexed($event);
    }
    if ( $event->{event_type} eq $ACTION_REVERSED ) {
        return $self->_index_reversal($event);
    }

    return $self->_index_aggregate($event);
}

sub _index_aggregate ( $self, $event ) {
    if ( ( $event->{aggregate_type} || q{} ) eq 'thread' ) {
        return $self->_index_thread_event($event);
    }
    if ( ( $event->{aggregate_type} || q{} ) eq 'post' ) {
        return $self->indexer->index_post( $event->{aggregate_id} );
    }

    my $undefined;
    return $undefined;
}

sub _index_thread_event ( $self, $event ) {
    my $thread_id = $event->{aggregate_id};
    if ( _reindex_thread_posts($event) ) {
        return $self->_reindex_thread( $thread_id, $event );
    }

    return $self->indexer->index_thread($thread_id);
}

# The thread's own document and the first batch of its posts now; the rest
# follow as their own outbox messages. Every post of a large thread in this
# one message held the dispatcher -- and every reply's realtime push,
# notifications and cache purge behind it -- for as long as it took.
sub _reindex_thread ( $self, $thread_id, $cause ) {
    my $result = $self->indexer->index_thread($thread_id);
    $result->{posts_indexed} =
      $self->_index_thread_posts( $thread_id, undef, $cause );

    return $result;
}

sub _index_thread_posts ( $self, $thread_id, $after, $cause ) {
    my $batch = $self->indexer->index_thread_posts_batch( $thread_id, $after );
    if ( defined $batch->{next_after} ) {
        $self->_request_thread_posts( $thread_id, $batch->{next_after},
            $cause );
    }

    return $batch;
}

# The next batch's event and outbox message, together or not at all, and
# once however often this message is retried: the key names the event that
# started the chain and where the next batch starts. Its own event type, not
# Search::RebuildRun's step: that would show every rename as the console's
# last rebuild and end each one by pruning the whole index. There is no
# prune here: index_post removes the document of a post that died, and each
# batch reads the posts as they are then, so a move, hide and restore in any
# order converge.
sub _request_thread_posts ( $self, $thread_id, $after, $cause ) {
    my $origin = _chain_origin($cause);
    croak 'a thread post batch needs the event that asked for it'
      if !defined $origin;

    my $key      = join q{:}, 'search.thread_posts', $origin, $after;
    my $recorder = $self->recorder;

    return $recorder->schema->txn_do(
        sub {
            return 0 if $recorder->event_recorded($key);

            return $recorder->record_event(
                actor_id        => $cause->{actor_id},
                aggregate_id    => $thread_id,
                aggregate_type  => 'thread',
                causation_id    => $cause->{event_id},
                correlation_id  => $cause->{correlation_id},
                event_type      => $THREAD_POSTS,
                idempotency_key => $key,
                payload         => {
                    after          => $after,
                    cause_event_id => $origin,
                    thread_id      => $thread_id,
                },
            );
        }
    );
}

# The event a chain of batches started from: the thread event itself, or,
# for a later batch, the one its payload names.
sub _chain_origin ($event) {
    if ( ( $event->{event_type} // q{} ) eq $THREAD_POSTS ) {
        return _payload($event)->{cause_event_id};
    }

    return $event->{event_id};
}

sub _reindex_thread_posts ($event) {
    my $event_type = $event->{event_type};
    if ( !defined $event_type ) {
        return 0;
    }

    return exists $THREAD_POST_REINDEX{$event_type} ? 1 : 0;
}

sub _remove_indexed ( $self, $event ) {
    if ( ( $event->{aggregate_type} || q{} ) eq 'thread' ) {
        return $self->indexer->remove_thread( $event->{aggregate_id} );
    }

    return $self->indexer->remove_post( $event->{aggregate_id} );
}

sub _index_reversal ( $self, $event ) {
    my $undefined;

    my $payload     = _payload($event);
    my $target_type = $payload->{target_type} || $event->{aggregate_type};
    my $target_id   = $payload->{target_id};

    return $undefined if !$target_id;

    if ( $target_type eq 'thread' ) {
        return $self->_reindex_thread( $target_id, $event );
    }
    if ( $target_type eq 'post' ) {
        return $self->indexer->index_post($target_id);
    }

    return $undefined;
}

sub _action_for ($event) {
    if ( _is_search_removal($event) ) {
        return 'search.remove';
    }
    if ( ( $event->{event_type} // q{} ) eq $REBUILD_STEP ) {
        return 'search.rebuild';
    }

    return 'search.index';
}

sub _payload ($event) {
    return $event->{domain_payload} || $event->{payload} || {};
}

sub _is_search_removal ($event) {
    my $event_type = $event->{event_type};
    if ( !defined $event_type ) {
        return 0;
    }

    return exists $SEARCH_REMOVAL{$event_type} ? 1 : 0;
}

1;
