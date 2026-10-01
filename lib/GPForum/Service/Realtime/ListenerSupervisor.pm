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

__END__

=head1 NAME

GPForum::Service::Realtime::ListenerSupervisor - Keeps the realtime PostgreSQL listener polled and reconnected.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $supervisor = GPForum::Service::Realtime::ListenerSupervisor->new(
        listener                   => $pg_listener,
        logger                     => $app->log,
        poll_interval_seconds      => 1,
        heartbeat_interval_seconds => 30,
        reconnect_backoff_seconds  => 5,
    );
    $supervisor->start;
    my $health = $supervisor->snapshot;

=head1 DESCRIPTION

Realtime events cross processes and nodes as PostgreSQL notifications, which
L<GPForum::Service::Realtime::PgListener> receives. This supervisor drives
that listener from the Mojo::IOLoop: it starts it, polls it on a recurring
timer and logs a debug heartbeat. A failed start is retried after
C<reconnect_backoff_seconds>; a failed poll reconnects at once, and then
every C<reconnect_backoff_seconds> until a reconnect succeeds. Once started,
it stops the listener and its timers when the IOLoop finishes.

A listener that fails does not take the request down: its C<start>, C<stop>,
C<poll_once> and C<reconnect> calls are wrapped in C<eval>. A failed start or
poll is reported as a C<degraded> status, and the supervisor counts what
it does in C<stats> (C<starts>, C<stops>, C<polls>, C<poll_failures>,
C<reconnects>, C<degraded>, C<heartbeats>, C<scheduled_polls>).

The C<listener> attribute must answer C<start>, C<stop>, C<poll_once> and
C<reconnect> with a hash reference whose C<ok> is true on success, and may
answer C<snapshot>. C<enabled> (default 1) turns the whole supervisor off.

=head1 SUBROUTINES/METHODS

=head2 start

Takes an optional hash reference; C<without_timers> starts the listener
without scheduling the poll, heartbeat or reconnect timers. Returns
C<< { ok => 0, status => 'disabled', reason => 'disabled' } >> when
disabled, C<< { ok => 1, status => 'running', idempotent => 1 } >> when
already running, C<< { ok => 1, status => 'running', listener => $result } >>
when the listener started, and
C<< { ok => 0, degraded => 1, status => 'degraded', reason => $reason } >>
when it did not (C<$reason> is the listener's, or C<listener_failed> when it
died); a reconnect is then scheduled unless C<without_timers> was given.

=head2 stop

Removes the timers, stops the listener (ignoring its errors), marks the
supervisor not running, and returns C<< { ok => 1, status => 'stopped' } >>.

=head2 poll_once

Polls the listener once, starting it first (without timers) when it is not
running. Returns the disabled hash when disabled, the failed start's hash
when starting failed, the listener's own result on success, and
C<< { ok => 0, degraded => 1, status => 'degraded', reason => $reason } >>
when the poll failed (C<$reason> is the listener's, or C<poll_failed>), after
trying one reconnect.

=head2 snapshot

Returns C<enabled>, C<running>, a copy of C<stats>, and the listener's own
C<snapshot> (or an empty hash when it has none).

=head1 DIAGNOSTICS

None. Listener failures are caught and returned as C<degraded>; when the
listener dies, its message is not kept.

=head1 CONFIGURATION AND ENVIRONMENT

The module reads no environment itself. L<GPForum::Bootstrap::Core> builds it
from C<GPFORUM_REALTIME_LISTENER_ENABLED>,
C<GPFORUM_REALTIME_LISTENER_POLL_INTERVAL_SECONDS>,
C<GPFORUM_REALTIME_LISTENER_HEARTBEAT_INTERVAL_SECONDS> and
C<GPFORUM_REALTIME_LISTENER_RECONNECT_BACKOFF_SECONDS> through
L<GPForum::Config>, and, when the listener is enabled, calls L</start> before
each request is dispatched.

=head1 DEPENDENCIES

L<Mojo::IOLoop>,
L<Scalar::Util>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The heartbeat only logs at debug level and counts; it does not probe the
listener. The reconnect backoff is fixed, not exponential. L</snapshot> calls
the listener's C<snapshot> without an C<eval>, so an error there propagates.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
