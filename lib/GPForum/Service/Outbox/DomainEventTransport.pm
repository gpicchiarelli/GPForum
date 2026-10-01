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

__END__

=head1 NAME

GPForum::Service::Outbox::DomainEventTransport - Delivers one outbox event to its handlers and to realtime.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $transport = GPForum::Service::Outbox::DomainEventTransport->new(
        handlers          => [ $search_handler, $notification_handler ],
        job_runner        => $idempotent_job_runner,
        realtime_notifier => $pg_notifier,
    );
    my $summary = $transport->dispatch($outbox_message);

=head1 DESCRIPTION

The transport L<GPForum::Service::Outbox::Dispatcher> hands each claimed
outbox message to. It normalizes the message's payload with
L<GPForum::Jobs::EventPayload>, runs every handler that supports the event,
and then sends the realtime hint the event maps to.

With a C<job_runner>, each handler run and the realtime hint go through it
under an idempotency key from L<GPForum::Service::Outbox::HandlerIdempotency>
(handler prefix or realtime prefix, plus the event id). A message that is
delivered again after a partial failure then skips the work already marked
done instead of repeating it. Without a job runner, or for a handler or event
that has no key, the work simply runs.

Attributes: C<handlers> (objects with C<supports($payload)> and
C<handle($payload)>), C<job_runner> (optional; C<run($key, $code,
$event_id)>), C<realtime_notifier> (optional; C<notify($event)>),
C<realtime_mapper>, C<catalog> and C<payload_contract>.

=head1 SUBROUTINES/METHODS

=head2 dispatch

Takes the outbox message row (anything with C<get_column('payload')>).
Returns C<< { ok => 1, handlers => $count, results => \@results } >>, one
result per handler that ran (C<< { skipped => 1, idempotency_key => $key } >>
for one the job runner had already done), plus C<realtime> when a realtime
notifier is set and the event maps to at least one realtime event:
C<< { events => $count, results => \@results } >>, or the skipped hash.

=head1 DIAGNOSTICS

A handler's or notifier's exception propagates. Under a job runner, a failed
run croaks with the runner's error, or C<idempotent handler failed> when it
gives none. The dispatcher records either as a failed delivery attempt.

=head1 CONFIGURATION AND ENVIRONMENT

None. L<GPForum::Bootstrap::Workers> builds it with the application's
handlers, job runner and PostgreSQL notifier.

=head1 DEPENDENCIES

L<GPForum::Jobs::EventPayload>,
L<GPForum::Service::Outbox::HandlerIdempotency>,
L<GPForum::Service::Realtime::OutboxEventMapper>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Handlers run one after another in the order given; one that dies stops the
rest and the realtime hint for that delivery.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
