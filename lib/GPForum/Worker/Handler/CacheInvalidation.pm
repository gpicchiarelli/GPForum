package GPForum::Worker::Handler::CacheInvalidation;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

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

const my %SUPPORTED => (
    $CATEGORY_CREATED => 1,
    $CATEGORY_UPDATED => 1,
    $POST_CREATED     => 1,
    $POST_DELETED     => 1,
    $POST_UNDELETED   => 1,
    $POST_UPDATED     => 1,
    $THREAD_CREATED   => 1,
    $THREAD_DELETED   => 1,
    $THREAD_HIDDEN    => 1,
    $THREAD_MOVED     => 1,
    $THREAD_RESTORED  => 1,
    $THREAD_UNDELETED => 1,
    $THREAD_UPDATED   => 1,
);

const my %THREAD_CONTENT => (
    $THREAD_CREATED   => 1,
    $THREAD_DELETED   => 1,
    $THREAD_HIDDEN    => 1,
    $THREAD_MOVED     => 1,
    $THREAD_RESTORED  => 1,
    $THREAD_UNDELETED => 1,
    $THREAD_UPDATED   => 1,
);

const my %POST_CONTENT => (
    $POST_CREATED   => 1,
    $POST_DELETED   => 1,
    $POST_UNDELETED => 1,
    $POST_UPDATED   => 1,
);

has sink  => undef;
has cache => undef;

sub supports {
    my ( undef, $event ) = @_;

    return _supported_event( $event->{event_type} );
}

sub handle {
    my ( $self, $event ) = @_;

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

sub _invalidate_tags {
    my ( $self, $tags ) = @_;

    for my $tag ( @{$tags} ) {
        $self->cache->invalidate_tag($tag);
    }

    return;
}

sub _tags_for {
    my ($event) = @_;

    my $event_type = $event->{event_type};
    if ( _thread_content_event($event_type) ) {
        return _thread_tags($event);
    }
    if ( _post_content_event($event_type) ) {
        return _post_tags($event);
    }
    if ( _supported_event($event_type) ) {
        return _category_tags($event);
    }

    return [];
}

sub _thread_content_event {
    my ($event_type) = @_;

    if ( !defined $event_type ) {
        return 0;
    }

    return exists $THREAD_CONTENT{$event_type} ? 1 : 0;
}

sub _post_content_event {
    my ($event_type) = @_;

    if ( !defined $event_type ) {
        return 0;
    }

    return exists $POST_CONTENT{$event_type} ? 1 : 0;
}

sub _supported_event {
    my ($event_type) = @_;

    if ( !defined $event_type ) {
        return 0;
    }
    if ( exists $SUPPORTED{$event_type} ) {
        return 1;
    }

    return 0;
}

sub _thread_tags {
    my ($event) = @_;

    my @tags = qw(threads forum-index);
    push @tags, join q{:}, 'thread', $event->{aggregate_id};
    push @tags, _named_tag( $event, 'category' );
    push @tags, _previous_category_tag($event);

    return [ grep { defined } @tags ];
}

sub _post_tags {
    my ($event) = @_;

    my @tags = ('posts');
    push @tags, join q{:}, 'post', $event->{aggregate_id};
    push @tags, _named_tag( $event, 'thread' );

    return [ grep { defined } @tags ];
}

sub _category_tags {
    my ($event) = @_;

    my $category_id = $event->{aggregate_id}
      || _event_value( $event, 'category_id' );
    my @tags = qw(categories forum-index forum:categories);
    if ( defined $category_id ) {
        push @tags, join q{:}, 'category',       $category_id;
        push @tags, join q{:}, 'forum:category', $category_id;
    }

    return \@tags;
}

sub _named_tag {
    my ( $event, $name ) = @_;

    my $value = _event_value( $event, $name . '_id' );
    if ( !defined $value ) {
        return;
    }

    return join q{:}, $name, $value;
}

sub _previous_category_tag {
    my ($event) = @_;

    my $value = _event_value( $event, 'previous_category_id' );
    if ( !defined $value ) {
        return;
    }

    return join q{:}, 'category', $value;
}

sub _event_value {
    my ( $event, $name ) = @_;

    if ( defined $event->{$name} ) {
        return $event->{$name};
    }

    my $payload = $event->{domain_payload} || {};

    return $payload->{$name};
}

1;
