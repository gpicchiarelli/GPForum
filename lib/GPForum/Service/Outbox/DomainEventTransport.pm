# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Outbox::DomainEventTransport;

use strict;
use warnings;

use Carp qw(croak);
use GPForum::Jobs::EventPayload;
use GPForum::Service::Realtime::OutboxEventMapper;
use GPForum::Service::Outbox::HandlerIdempotency;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

has catalog =>
  sub { return GPForum::Service::Outbox::HandlerIdempotency->new; };
has handlers         => sub { return []; };
has job_runner       => undef;
has payload_contract => sub { return GPForum::Jobs::EventPayload->new; };
has realtime_mapper =>
  sub { return GPForum::Service::Realtime::OutboxEventMapper->new; };
has realtime_notifier => undef;

sub dispatch ( $self, $message ) {
    my $payload =
      $self->payload_contract->normalize( $message->get_column('payload') );
    my @results  = $self->_handler_results($payload);
    my $realtime = $self->_notify_realtime($payload);

    return {
        ok       => 1,
        handlers => scalar @results,
        results  => \@results,
        ( $realtime ? ( realtime => $realtime ) : () ),
    };
}

sub _handler_results ( $self, $payload ) {
    my @results;
    for my $handler ( @{ $self->handlers } ) {
        if ( !$handler->supports($payload) ) {
            next;
        }
        push @results, $self->_run_handler( $handler, $payload );
    }

    return @results;
}

sub _run_handler ( $self, $handler, $payload ) {
    my $key = $self->_handler_key( $handler, $payload );
    if ( !length $key ) {
        return $handler->handle($payload);
    }

    return $self->_run_idempotent( $key,
        sub { return $handler->handle($payload); },
        $payload->{event_id} );
}

sub _handler_key ( $self, $handler, $payload ) {
    if ( !$self->job_runner ) {
        return q{};
    }

    return $self->catalog->key_for( $handler, $payload );
}

# The event id is passed rather than parsed back out of the key. The store
# writes it to a uuid column when it claims the key, and reconstructing it
# from the key's suffix only works while every key happens to end in one.
sub _run_idempotent ( $self, $key, $code, $event_id ) {
    my $outcome = $self->job_runner->run( $key, $code, $event_id );
    if ( !$outcome->{ok} ) {
        croak $outcome->{error} || 'idempotent handler failed';
    }
    if ( $outcome->{skipped} ) {
        return { skipped => 1, idempotency_key => $key };
    }

    return $outcome->{result};
}

sub _notify_realtime ( $self, $payload ) {
    if ( !$self->realtime_notifier ) {
        my $undefined;
        return $undefined;
    }

    my $key = $self->_realtime_key($payload);
    if ( !length $key ) {
        return $self->_dispatch_realtime($payload);
    }

    return $self->_run_idempotent( $key,
        sub { return $self->_dispatch_realtime($payload); },
        $payload->{event_id} );
}

sub _realtime_key ( $self, $payload ) {
    if ( !$self->job_runner ) {
        return q{};
    }

    return $self->catalog->realtime_key($payload);
}

# The domain event's hint only. A notification handler's badges were NOTIFYed
# by the dispatcher that created them.
sub _dispatch_realtime ( $self, $payload ) {
    my @events = $self->realtime_mapper->events_for_payload($payload);
    if ( !@events ) {
        my $undefined;
        return $undefined;
    }

    my @results;
    for my $event (@events) {
        push @results, $self->realtime_notifier->notify($event);
    }

    return { events => scalar @events, results => \@results };
}

1;
