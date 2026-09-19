package GPForum::Worker::Handler::CacheInvalidation;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $THREAD_CREATED   => 'thread.created';
const my $POST_CREATED     => 'post.created';
const my $CATEGORY_CREATED => 'category.created';
const my $CATEGORY_UPDATED => 'category.updated';

const my %SUPPORTED => (
    $CATEGORY_CREATED => 1,
    $CATEGORY_UPDATED => 1,
    $POST_CREATED     => 1,
    $THREAD_CREATED   => 1,
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
    if ( $event_type eq $THREAD_CREATED ) {
        return _thread_tags($event);
    }
    if ( $event_type eq $POST_CREATED ) {
        return _post_tags($event);
    }
    if ( _supported_event($event_type) ) {
        return _category_tags($event);
    }

    return [];
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

sub _event_value {
    my ( $event, $name ) = @_;

    if ( defined $event->{$name} ) {
        return $event->{$name};
    }

    my $payload = $event->{domain_payload} || {};

    return $payload->{$name};
}

1;
