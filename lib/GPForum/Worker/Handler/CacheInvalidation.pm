# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Worker::Handler::CacheInvalidation;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

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

has sink  => undef;    # optional: tests capture tasks
has cache => undef;    # optional: nothing to invalidate

sub supports ( $, $event ) {
    return exists $SUPPORTED{ $event->{event_type} // q{} } ? 1 : 0;
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
        for my $tag ( @{ $task->{tags} } ) {
            $self->cache->invalidate_tag($tag);
        }
    }

    return $task;
}

sub _tags_for ($event) {
    my $event_type = $event->{event_type} // q{};
    my $tags       = _content_tags( $event, $event_type );
    if ( exists $PURGES_PUBLIC_HTML{$event_type} ) {
        push @{$tags}, $PUBLIC_HTML;
    }

    return $tags;
}

sub _content_tags ( $event, $event_type ) {
    return _thread_tags($event) if exists $THREAD_CONTENT{$event_type};
    return _post_tags($event)   if exists $POST_CONTENT{$event_type};
    return [qw(threads posts forum-index)] if $event_type eq $ACTION_REVERSED;
    return _category_tags($event)          if exists $SUPPORTED{$event_type};

    return [];
}

# The reader caches' tags, then the public HTML pages that show the thread:
# its own page and its category's (and, for a move, the one it left).
sub _thread_tags ($event) {
    my $thread_id  = $event->{aggregate_id} // q{};
    my @categories = map { "category:$_" }
      grep { defined }
      map { _event_value( $event, $_ ) } qw(category_id previous_category_id);

    return [
        qw(threads forum-index), "thread:$thread_id",
        @categories,             "forum:thread:$thread_id",
        map { "forum:$_" } @categories,
    ];
}

# A post shows on its thread's public page.
sub _post_tags ($event) {
    my $post_id   = $event->{aggregate_id} // q{};
    my $thread_id = _event_value( $event, 'thread_id' );
    my @thread    = defined $thread_id ? ("thread:$thread_id") : ();

    return [ 'posts', "post:$post_id", @thread, map { "forum:$_" } @thread ];
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

sub _event_value ( $event, $name ) {
    if ( defined $event->{$name} ) {
        return $event->{$name};
    }

    my $payload = $event->{domain_payload} || {};

    return $payload->{$name};
}

1;
