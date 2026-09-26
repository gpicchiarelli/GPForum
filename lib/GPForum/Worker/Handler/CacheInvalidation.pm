# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Worker::Handler::CacheInvalidation;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $THREAD_CREATED   => 'thread.created';
const my $THREAD_UPDATED   => 'thread.updated';
const my $THREAD_DELETED   => 'thread.deleted';
const my $THREAD_MOVED     => 'thread.moved';
const my $THREAD_HIDDEN    => 'thread.hidden';
const my $THREAD_RESTORED  => 'thread.restored';
const my $THREAD_UNDELETED => 'thread.undeleted';
const my $POST_CREATED     => 'post.created';
const my $POST_UPDATED     => 'post.updated';
const my $POST_DELETED     => 'post.deleted';
const my $POST_UNDELETED   => 'post.undeleted';
const my $CATEGORY_CREATED => 'category.created';
const my $CATEGORY_UPDATED => 'category.updated';
const my $POST_HIDDEN      => 'post.hidden';
const my $POST_RESTORED    => 'post.restored';
const my $THREAD_LOCKED    => 'thread.locked';
const my $THREAD_UNLOCKED  => 'thread.unlocked';
const my $ACTION_REVERSED  => 'moderation_action.reversed';

# Every page of the public HTML cache carries this tag (Web::ForumAccess).
const my $PUBLIC_HTML => 'forum:public-html';

const my %SUPPORTED => (
    $ACTION_REVERSED  => 1,
    $CATEGORY_CREATED => 1,
    $CATEGORY_UPDATED => 1,
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

# Events that change what anonymous readers may see across pages the event
# does not name: moderation (whose events carry only the target) and a
# category's title or visibility (shown on, and deciding, every page of its
# threads). They purge the whole public HTML cache; they are rare. Until
# they did, a hidden thread or a category turned private stayed on the
# cached public pages until the entry expired.
const my %PURGES_PUBLIC_HTML => (
    $ACTION_REVERSED  => 1,
    $CATEGORY_CREATED => 1,
    $CATEGORY_UPDATED => 1,
    $POST_HIDDEN      => 1,
    $POST_RESTORED    => 1,
    $THREAD_HIDDEN    => 1,
    $THREAD_LOCKED    => 1,
    $THREAD_RESTORED  => 1,
    $THREAD_UNLOCKED  => 1,
);

const my %THREAD_CONTENT => (
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

const my %POST_CONTENT => (
    $POST_CREATED   => 1,
    $POST_DELETED   => 1,
    $POST_HIDDEN    => 1,
    $POST_RESTORED  => 1,
    $POST_UNDELETED => 1,
    $POST_UPDATED   => 1,
);

has sink  => undef;
has cache => undef;

sub supports ( $, $event ) {
    return _supported_event( $event->{event_type} );
}

sub handle ( $self, $event ) {
    my $task = {
        action         => 'cache.invalidate',
        aggregate_type => $event->{aggregate_type},
        aggregate_id   => $event->{aggregate_id},
        event_id       => $event->{event_id},
        tags           => _tags_for($event),
    };

    if ( $self->sink ) {
        $self->sink->capture($task);
    }

    if ( $self->cache ) {
        $self->_invalidate_tags( $task->{tags} );
    }

    return $task;
}

sub _invalidate_tags ( $self, $tags ) {
    for my $tag ( @{$tags} ) {
        $self->cache->invalidate_tag($tag);
    }

    return;
}

sub _tags_for ($event) {
    my $event_type = $event->{event_type} // q{};
    my $tags       = _content_tags($event);
    if ( exists $PURGES_PUBLIC_HTML{$event_type} ) {
        push @{$tags}, $PUBLIC_HTML;
    }

    return $tags;
}

sub _content_tags ($event) {
    my $event_type = $event->{event_type};
    if ( _thread_content_event($event_type) ) {
        return _thread_tags($event);
    }
    if ( _post_content_event($event_type) ) {
        return _post_tags($event);
    }
    if ( ( $event_type // q{} ) eq $ACTION_REVERSED ) {
        return [qw(threads posts forum-index)];
    }
    if ( _supported_event($event_type) ) {
        return _category_tags($event);
    }

    return [];
}

sub _thread_content_event ($event_type) {
    if ( !defined $event_type ) {
        return 0;
    }

    return exists $THREAD_CONTENT{$event_type} ? 1 : 0;
}

sub _post_content_event ($event_type) {
    if ( !defined $event_type ) {
        return 0;
    }

    return exists $POST_CONTENT{$event_type} ? 1 : 0;
}

sub _supported_event ($event_type) {
    if ( !defined $event_type ) {
        return 0;
    }
    if ( exists $SUPPORTED{$event_type} ) {
        return 1;
    }

    return 0;
}

# The reader caches' tags, then the public HTML pages that show the thread:
# its own page and its category's (and, for a move, the one it left).
sub _thread_tags ($event) {
    my @tags = qw(threads forum-index);
    push @tags, join q{:}, 'thread', $event->{aggregate_id};
    push @tags, _named_tag( $event, 'category' );
    push @tags, _previous_category_tag($event);
    push @tags, join q{:}, 'forum:thread', $event->{aggregate_id};
    push @tags,
      map { defined $_ ? "forum:$_" : undef } _named_tag( $event, 'category' ),
      _previous_category_tag($event);

    return [ grep { defined } @tags ];
}

# A post shows on its thread's public page.
sub _post_tags ($event) {
    my @tags = ('posts');
    push @tags, join q{:}, 'post', $event->{aggregate_id};
    push @tags, _named_tag( $event, 'thread' );
    push @tags,
      map { defined $_ ? "forum:$_" : undef } _named_tag( $event, 'thread' );

    return [ grep { defined } @tags ];
}

sub _category_tags ($event) {
    my $category_id = $event->{aggregate_id}
      || _event_value( $event, 'category_id' );
    my @tags = qw(categories forum-index forum:categories);
    if ( defined $category_id ) {
        push @tags, join q{:}, 'category',       $category_id;
        push @tags, join q{:}, 'forum:category', $category_id;
    }

    return \@tags;
}

sub _named_tag ( $event, $name ) {
    my $value = _event_value( $event, $name . '_id' );
    if ( !defined $value ) {
        return;
    }

    return join q{:}, $name, $value;
}

sub _previous_category_tag ($event) {
    my $value = _event_value( $event, 'previous_category_id' );
    if ( !defined $value ) {
        return;
    }

    return join q{:}, 'category', $value;
}

sub _event_value ( $event, $name ) {
    if ( defined $event->{$name} ) {
        return $event->{$name};
    }

    my $payload = $event->{domain_payload} || {};

    return $payload->{$name};
}

1;
