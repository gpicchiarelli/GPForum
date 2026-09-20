package GPForum::Worker::HandlerIdempotency;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $REALTIME_PREFIX => 'worker.realtime';

const my %PREFIX => (
    'GPForum::Worker::Handler::AttachmentScanning'   => 'worker.attachment',
    'GPForum::Worker::Handler::CacheInvalidation'    => 'worker.cache',
    'GPForum::Worker::Handler::FeedProjection'       => 'worker.feed',
    'GPForum::Worker::Handler::MediaProcessing'      => 'worker.media',
    'GPForum::Worker::Handler::NotificationDispatch' => 'worker.notification',
    'GPForum::Worker::Handler::ReputationUpdate'     => 'worker.reputation',
    'GPForum::Worker::Handler::SearchIndexing'       => 'worker.search',
);

sub prefix_for {
    my ( undef, $handler ) = @_;

    my $class = _handler_class($handler);
    if ( !length $class || !exists $PREFIX{$class} ) {
        return q{};
    }

    return $PREFIX{$class};
}

sub key_for {
    my ( $self, $handler, $event ) = @_;

    my $prefix   = $self->prefix_for($handler);
    my $event_id = _event_id($event);
    if ( !length $prefix || !length $event_id ) {
        return q{};
    }

    return join q{:}, $prefix, $event_id;
}

sub realtime_key {
    my ( undef, $event ) = @_;

    my $event_id = _event_id($event);
    if ( !length $event_id ) {
        return q{};
    }

    return join q{:}, $REALTIME_PREFIX, $event_id;
}

sub _handler_class {
    my ($handler) = @_;

    my $class = ref $handler;
    if ($class) {
        return $class;
    }
    if ( defined $handler ) {
        return $handler;
    }

    return q{};
}

sub _event_id {
    my ($event) = @_;

    if ( ref $event ne 'HASH' ) {
        return q{};
    }

    my $event_id = $event->{event_id};
    if ( !defined $event_id || !length $event_id ) {
        return q{};
    }

    return $event_id;
}

1;
