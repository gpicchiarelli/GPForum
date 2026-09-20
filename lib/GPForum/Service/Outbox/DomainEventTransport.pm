package GPForum::Service::Outbox::DomainEventTransport;

use strict;
use warnings;

use Carp qw(croak);
use GPForum::Jobs::EventPayload;
use GPForum::Service::Realtime::OutboxEventMapper;
use GPForum::Worker::HandlerIdempotency;
use Mojo::Base -base;

our $VERSION = '0.001';

has catalog    => sub { return GPForum::Worker::HandlerIdempotency->new; };
has handlers   => sub { return []; };
has job_runner => undef;
has payload_contract => sub { return GPForum::Jobs::EventPayload->new; };
has realtime_mapper =>
  sub { return GPForum::Service::Realtime::OutboxEventMapper->new; };
has realtime_notifier => undef;

sub dispatch {
    my ( $self, $message ) = @_;

    my $payload =
      $self->payload_contract->normalize( $message->get_column('payload') );
    my @results  = $self->_handler_results($payload);
    my $realtime = $self->_notify_realtime( $payload, \@results );

    return {
        ok       => 1,
        handlers => scalar @results,
        results  => \@results,
        ( $realtime ? ( realtime => $realtime ) : () ),
    };
}

sub _handler_results {
    my ( $self, $payload ) = @_;

    my @results;
    for my $handler ( @{ $self->handlers } ) {
        if ( !$handler->supports($payload) ) {
            next;
        }
        push @results, $self->_run_handler( $handler, $payload );
    }

    return @results;
}

sub _run_handler {
    my ( $self, $handler, $payload ) = @_;

    my $key = $self->_handler_key( $handler, $payload );
    if ( !length $key ) {
        return $handler->handle($payload);
    }

    return $self->_run_idempotent( $key,
        sub { return $handler->handle($payload); } );
}

sub _handler_key {
    my ( $self, $handler, $payload ) = @_;

    if ( !$self->job_runner ) {
        return q{};
    }

    return $self->catalog->key_for( $handler, $payload );
}

sub _run_idempotent {
    my ( $self, $key, $code ) = @_;

    my $outcome = $self->job_runner->run( $key, $code );
    if ( !$outcome->{ok} ) {
        croak $outcome->{error} || 'idempotent handler failed';
    }
    if ( $outcome->{skipped} ) {
        return { skipped => 1, idempotency_key => $key };
    }

    return $outcome->{result};
}

sub _notify_realtime {
    my ( $self, $payload, $handler_results ) = @_;

    if ( !$self->realtime_notifier ) {
        return;
    }

    my $key = $self->_realtime_key($payload);
    if ( !length $key ) {
        return $self->_dispatch_realtime( $payload, $handler_results );
    }

    return $self->_run_idempotent(
        $key,
        sub {
            return $self->_dispatch_realtime( $payload, $handler_results );
        }
    );
}

sub _realtime_key {
    my ( $self, $payload ) = @_;

    if ( !$self->job_runner ) {
        return q{};
    }

    return $self->catalog->realtime_key($payload);
}

sub _dispatch_realtime {
    my ( $self, $payload, $handler_results ) = @_;

    my @events =
      $self->realtime_mapper->events_for_payload( $payload, $handler_results );
    if ( !@events ) {
        return;
    }

    my @results;
    for my $event (@events) {
        push @results, $self->realtime_notifier->notify($event);
    }

    return { events => scalar @events, results => \@results };
}

1;
