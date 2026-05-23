package GPForum::Worker::Handler::CacheInvalidation;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $THREAD_CREATED => 'thread.created';
const my $POST_CREATED   => 'post.created';

has sink  => undef;
has cache => undef;

sub supports {
    my ( $self, $event ) = @_;

    return $event->{event_type} eq $THREAD_CREATED
      || $event->{event_type} eq $POST_CREATED;
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
        for my $tag ( @{ $task->{tags} } ) {
            $self->cache->invalidate_tag($tag);
        }
    }

    return $task;
}

sub _tags_for {
    my ($event) = @_;

    return _thread_tags($event) if $event->{event_type} eq $THREAD_CREATED;
    return _post_tags($event)   if $event->{event_type} eq $POST_CREATED;

    return [];
}

sub _thread_tags {
    my ($event) = @_;

    my @tags = qw(threads forum-index);
    push @tags, join q{:}, 'thread', $event->{aggregate_id};

    my $category_id = _event_value( $event, 'category_id' );
    if ( defined $category_id ) {
        push @tags, join q{:}, 'category', $category_id;
    }

    return \@tags;
}

sub _post_tags {
    my ($event) = @_;

    my @tags = ('posts');
    push @tags, join q{:}, 'post', $event->{aggregate_id};

    my $thread_id = _event_value( $event, 'thread_id' );
    if ( defined $thread_id ) {
        push @tags, join q{:}, 'thread', $thread_id;
    }

    return \@tags;
}

sub _event_value {
    my ( $event, $name ) = @_;

    return $event->{$name} if defined $event->{$name};

    my $payload = $event->{domain_payload} || {};

    return $payload->{$name};
}

1;
