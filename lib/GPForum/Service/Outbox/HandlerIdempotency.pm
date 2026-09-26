# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Outbox::HandlerIdempotency;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

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
    'GPForum::Worker::Handler::ThreadActivity' => 'worker.thread_activity',
);

sub prefix_for ( $, $handler ) {
    my $class = _handler_class($handler);
    if ( !length $class || !exists $PREFIX{$class} ) {
        return q{};
    }

    return $PREFIX{$class};
}

sub key_for ( $self, $handler, $event ) {
    my $prefix   = $self->prefix_for($handler);
    my $event_id = _event_id($event);
    if ( !length $prefix || !length $event_id ) {
        return q{};
    }

    return join q{:}, $prefix, $event_id;
}

sub realtime_key ( $, $event ) {
    my $event_id = _event_id($event);
    if ( !length $event_id ) {
        return q{};
    }

    return join q{:}, $REALTIME_PREFIX, $event_id;
}

sub _handler_class ($handler) {
    my $class = ref $handler;
    if ($class) {
        return $class;
    }
    if ( defined $handler ) {
        return $handler;
    }

    return q{};
}

sub _event_id ($event) {
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
