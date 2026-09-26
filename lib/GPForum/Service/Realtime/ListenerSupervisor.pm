# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::ListenerSupervisor;

use strict;
use warnings;

use Mojo::Base -base, -signatures;
use Mojo::IOLoop;
use Scalar::Util qw(weaken);

our $VERSION = '0.001';

has enabled                    => 1;
has heartbeat_interval_seconds => 30;
has ioloop                     => sub { return Mojo::IOLoop->singleton; };
has listener                   => undef;
has logger                     => undef;
has poll_interval_seconds      => 1;
has reconnect_backoff_seconds  => 5;
has reconnect_timer_id         => undef;
has heartbeat_timer_id         => undef;
has finish_handler_registered  => 0;
has poll_timer_id              => undef;
has running                    => 0;
has stats                      => sub {
    return {
        degraded        => 0,
        heartbeats      => 0,
        poll_failures   => 0,
        polls           => 0,
        reconnects      => 0,
        scheduled_polls => 0,
        starts          => 0,
        stops           => 0,
    };
};

sub start ( $self, $options = undef ) {
    $options ||= {};
    return { ok => 0, status => 'disabled', reason => 'disabled' }
      if !$self->enabled;
    return { ok => 1, status => 'running', idempotent => 1 }
      if $self->running;

    my $started = eval { return $self->listener->start; };
    if ( !$started || !$started->{ok} ) {
        $self->stats->{degraded} += 1;
        $self->_schedule_reconnect if !$options->{without_timers};
        return {
            ok       => 0,
            degraded => 1,
            status   => 'degraded',
            reason   => $started ? $started->{reason} : 'listener_failed',
        };
    }

    $self->running(1);
    $self->stats->{starts} += 1;
    $self->_register_finish_handler;
    $self->_schedule_timers if !$options->{without_timers};

    return {
        ok       => 1,
        status   => 'running',
        listener => $started,
    };
}

sub stop ($self) {
    $self->_remove_timer('poll_timer_id');
    $self->_remove_timer('heartbeat_timer_id');
    $self->_remove_timer('reconnect_timer_id');
    eval { $self->listener->stop } if $self->listener;
    $self->running(0);
    $self->stats->{stops} += 1;

    return { ok => 1, status => 'stopped' };
}

sub poll_once ($self) {
    return { ok => 0, status => 'disabled', reason => 'disabled' }
      if !$self->enabled;
    my $started;
    if ( !$self->running ) {
        $started = $self->start( { without_timers => 1 } );
    }
    return $started if $started && !$started->{ok};

    my $result = eval { return $self->listener->poll_once; };
    $self->stats->{polls} += 1;

    if ( !$result || !$result->{ok} ) {
        $self->stats->{poll_failures} += 1;
        $self->_reconnect_now;
        return {
            ok       => 0,
            degraded => 1,
            status   => 'degraded',
            reason   => $result ? $result->{reason} : 'poll_failed',
        };
    }

    return $result;
}

sub snapshot ($self) {
    return {
        enabled  => $self->enabled ? 1 : 0,
        running  => $self->running ? 1 : 0,
        stats    => { %{ $self->stats } },
        listener => $self->listener && $self->listener->can('snapshot')
        ? $self->listener->snapshot
        : {},
    };
}

sub _schedule_timers ($self) {
    return if !$self->ioloop;

    if ( !defined $self->poll_timer_id ) {
        $self->poll_timer_id(
            $self->ioloop->recurring(
                $self->poll_interval_seconds => sub {
                    $self->poll_once;
                }
            )
        );
        $self->stats->{scheduled_polls} += 1;
    }

    if ( !defined $self->heartbeat_timer_id ) {
        $self->heartbeat_timer_id(
            $self->ioloop->recurring(
                $self->heartbeat_interval_seconds => sub {
                    $self->_heartbeat;
                }
            )
        );
    }

    return;
}

sub _register_finish_handler ($self) {
    return if $self->finish_handler_registered;
    return if !$self->ioloop || !$self->ioloop->can('on');

    my $supervisor = $self;
    weaken $supervisor;
    $self->ioloop->on(
        finish => sub {
            return if !$supervisor || !$supervisor->running;

            $supervisor->stop;
        }
    );
    $self->finish_handler_registered(1);

    return;
}

sub _schedule_reconnect ($self) {
    return if !$self->ioloop || defined $self->reconnect_timer_id;

    $self->reconnect_timer_id(
        $self->ioloop->timer(
            $self->reconnect_backoff_seconds => sub {
                $self->reconnect_timer_id(undef);
                $self->_reconnect_now;
            }
        )
    );

    return;
}

sub _reconnect_now ($self) {
    my $undefined;

    $self->stats->{reconnects} += 1;
    my $result = eval { return $self->listener->reconnect; };

    if ( !$result || !$result->{ok} ) {
        $self->running(0);
        $self->_schedule_reconnect;
        return $undefined;
    }

    $self->running(1);
    $self->_schedule_timers;

    return $undefined;
}

sub _heartbeat ($self) {
    $self->stats->{heartbeats} += 1;
    if ( $self->logger && $self->logger->can('debug') ) {
        $self->logger->debug('realtime listener heartbeat');
    }

    return;
}

sub _remove_timer ( $self, $attribute ) {
    my $timer_id = $self->$attribute;
    return if !defined $timer_id || !$self->ioloop;

    $self->ioloop->remove($timer_id);
    $self->$attribute(undef);

    return;
}

1;
