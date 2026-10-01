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

__END__

=head1 NAME

GPForum::Service::Outbox::HandlerIdempotency - The idempotency key of each worker handler's run of a domain event.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $catalog = GPForum::Service::Outbox::HandlerIdempotency->new;
    my $key = $catalog->key_for( $handler, $payload );
    # 'worker.search:<event id>', or '' when the run has no key
    my $realtime = $catalog->realtime_key($payload);

=head1 DESCRIPTION

When the outbox delivers a domain event, each worker handler that supports
it runs once for that event, and the realtime hint is sent once.
L<GPForum::Service::Outbox::DomainEventTransport> claims a key for each of
those runs before it starts one, so a message delivered twice does not run
a handler twice. This module names the keys: a fixed prefix per handler
class, a colon, and the event id.

The prefixes are C<worker.attachment>, C<worker.cache>, C<worker.feed>,
C<worker.media>, C<worker.notification>, C<worker.reputation>,
C<worker.search> and C<worker.thread_activity> for the matching
C<GPForum::Worker::Handler::*> classes, and C<worker.realtime> for the
realtime hint. A handler class not in that list has no key, and the
transport then runs it without a claim.

=head1 SUBROUTINES/METHODS

=head2 prefix_for

Takes a handler object or class name. Returns its key prefix, or an empty
string for a class with none.

=head2 key_for

Takes a handler (object or class name) and a domain event hash reference.
Returns C<< <prefix>:<event_id> >>, or an empty string when the handler
has no prefix or the event has no C<event_id> (or is not a hash
reference).

=head2 realtime_key

Takes a domain event hash reference. Returns
C<< worker.realtime:<event_id> >>, or an empty string when the event has
no C<event_id> (or is not a hash reference).

=head1 DIAGNOSTICS

None. A missing key is the empty string, never an error.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A subclass of a listed handler has no prefix: the class is matched by
name, not by inheritance.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
