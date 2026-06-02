package GPForum::Service::Outbox::DomainEventTransport;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Jobs::EventPayload;
use GPForum::Service::Realtime::OutboxEventMapper;

our $VERSION = '0.001';

has handlers         => sub { return []; };
has payload_contract => sub { return GPForum::Jobs::EventPayload->new; };
has realtime_mapper =>
  sub { return GPForum::Service::Realtime::OutboxEventMapper->new; };
has realtime_notifier => undef;

sub dispatch {
    my ( $self, $message ) = @_;

    my $payload =
      $self->payload_contract->normalize( $message->get_column('payload') );
    my @results;

    for my $handler ( @{ $self->handlers } ) {
        next if !$handler->supports($payload);

        push @results, $handler->handle($payload);
    }
    my $realtime = $self->_notify_realtime( $payload, \@results );

    return {
        ok       => 1,
        handlers => scalar @results,
        results  => \@results,
        ( $realtime ? ( realtime => $realtime ) : () ),
    };
}

sub _notify_realtime {
    my ( $self, $payload, $handler_results ) = @_;

    return if !$self->realtime_notifier;

    my @events =
      $self->realtime_mapper->events_for_payload( $payload, $handler_results );
    return if !@events;

    my @results;
    for my $event (@events) {
        push @results, $self->realtime_notifier->notify($event);
    }

    return { events => scalar @events, results => \@results };
}

1;
