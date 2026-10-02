# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::ListenerSupervisor;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;
use Mojo::IOLoop;
use Scalar::Util qw(weaken);

our $VERSION = '0.001';

# Enough of a driver's message to name the failure in /metrics and the log;
# a DBI error can run to a whole statement.
const my $ERROR_TEXT_LIMIT => 300;

# The reason a failure is reported under when the listener died instead of
# giving one.
const my %FALLBACK_REASON => (
    poll      => 'poll_failed',
    reconnect => 'reconnect_failed',
    start     => 'listener_failed',
);

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

# What the listener last failed at, and with which message. A listener that
# died on start or poll was reported only as degraded, and its message was
# lost: /metrics said something broke but not what.
has last_error => undef;

# The message last logged for the listener (its start, poll and reconnect)
# and for its snapshot. A working poll, or a working snapshot, forgets its
# own: compared with last_error alone, which a recovery keeps, a second
# outage that failed as the first one did was never logged.
has logged_errors => sub { return {}; };
has poll_timer_id => undef;
has running       => 0;
has stats         => sub {
    return {
        degraded          => 0,
        heartbeats        => 0,
        poll_failures     => 0,
        polls             => 0,
        reconnects        => 0,
        scheduled_polls   => 0,
        snapshot_failures => 0,
        starts            => 0,
        stops             => 0,
    };
};
has status => 'stopped';

sub start ( $self, $options = undef ) {
    $options ||= {};
    return { ok => 0, status => 'disabled', reason => 'disabled' }
      if !$self->enabled;
    return { ok => 1, status => 'running', idempotent => 1 }
      if $self->running;

    my $started = eval { return $self->listener->start; };
    if ( !$started || !$started->{ok} ) {
        my $reason = $self->_record_failure( 'start', $started, $EVAL_ERROR );
        $self->stats->{degraded} += 1;
        $self->_schedule_reconnect if !$options->{without_timers};
        return {
            ok       => 0,
            degraded => 1,
            status   => 'degraded',
            reason   => $reason,
        };
    }

    $self->running(1);
    $self->status('running');
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
    $self->status('stopped');
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
        my $reason = $self->_record_failure( 'poll', $result, $EVAL_ERROR );
        $self->stats->{poll_failures} += 1;
        $self->_reconnect_now;
        return {
            ok       => 0,
            degraded => 1,
            status   => 'degraded',
            reason   => $reason,
        };
    }

    # The listener works again: its next failure is a new outage.
    delete $self->logged_errors->{listener};

    return $result;
}

# Read by /metrics and the admin console: a listener whose snapshot dies must
# not take either down with it, so its error is kept here instead.
sub snapshot ($self) {
    my $listener = $self->_listener_snapshot;

    return {
        enabled    => $self->enabled    ? 1                          : 0,
        last_error => $self->last_error ? { %{ $self->last_error } } : undef,
        listener   => $listener,
        running    => $self->running ? 1 : 0,
        stats      => { %{ $self->stats } },
        status     => $self->enabled ? $self->status : 'disabled',
    };
}

# A snapshot that died is reported on the listener field, not in last_error:
# snapshot() reads the listener first, so kept there it replaced the start
# or poll error on every read of /metrics, and a degraded listener showed
# only that its snapshot had failed.
sub _listener_snapshot ($self) {
    return {} if !$self->listener || !$self->listener->can('snapshot');

    my $snapshot = eval { return $self->listener->snapshot; };
    if ( ref $snapshot eq 'HASH' ) {
        delete $self->logged_errors->{snapshot};
        return $snapshot;
    }

    my $message =
      _error_text( $EVAL_ERROR || 'listener snapshot is not a hash' );
    $self->stats->{snapshot_failures} += 1;
    $self->_log_once( 'snapshot', 'snapshot', $message );

    return { error => $message, status => 'unavailable' };
}

# A failure the listener reported keeps its reason; one it died with is
# reported under the fallback reason, and its message is kept in last_error
# either way.
sub _record_failure ( $self, $during, $result, $error ) {
    my $fallback = $FALLBACK_REASON{$during};
    $self->status('degraded');
    if ( ref $result eq 'HASH' ) {
        my $reason = $result->{reason} || $fallback;
        $self->_remember_error( $during, $reason );
        return $reason;
    }

    $self->_remember_error( $during, $error || $fallback );

    return $fallback;
}

sub _remember_error ( $self, $during, $error ) {
    my $message = _error_text($error);
    $self->last_error( { during => $during, message => $message } );
    $self->_log_once( 'listener', $during, $message );

    return;
}

# Logged when the message changes, not on every attempt: a listener that
# cannot reach the database fails its start once a poll interval and its
# reconnect once a backoff, with the same message, and a warning a second
# buries the first one. The listener's failures and its snapshot's are
# remembered apart, so that neither hides the other.
sub _log_once ( $self, $kind, $during, $message ) {
    my $logged = $self->logged_errors;
    return if defined $logged->{$kind} && $logged->{$kind} eq $message;

    $logged->{$kind} = $message;
    if ( $self->logger && $self->logger->can('warn') ) {
        $self->logger->warn("realtime listener $during failed: $message");
    }

    return;
}

# The first line that says something: an error that opens with a newline
# read as an empty message.
sub _error_text ($error) {
    my ($line) = grep { /\S/msx } split /\n/msx, "$error";
    $line //= q{};
    $line =~ s/\A\s+|\s+\z//gmsx;

    return
      length $line > $ERROR_TEXT_LIMIT
      ? substr( $line, 0, $ERROR_TEXT_LIMIT )
      : $line;
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
        $self->_record_failure( 'reconnect', $result, $EVAL_ERROR );
        $self->running(0);
        $self->_schedule_reconnect;
        return $undefined;
    }

    $self->running(1);
    $self->status('running');
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
C<poll_once>, C<reconnect> and C<snapshot> calls are wrapped in C<eval>. A
failed start, poll or reconnect turns C<status> to C<degraded> and is kept
in C<last_error> -- what failed (C<during>: C<start>, C<poll> or
C<reconnect>) and the listener's reason or, when it died, the first
non-blank line of its message. A listener snapshot that dies is reported
on the snapshot's C<listener> field instead, so that it never hides the
error the listener is degraded by. A failure is logged as a warning when
its message changes, or when it is the first failure since a poll worked
(since a snapshot worked, for a snapshot failure): a repeated attempt is
not logged again, a second outage is. The supervisor counts what it does
in C<stats> (C<starts>,
C<stops>, C<polls>, C<poll_failures>, C<reconnects>, C<degraded>,
C<heartbeats>, C<scheduled_polls>, C<snapshot_failures>).

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

Returns C<enabled>, C<running>, C<status> (C<stopped>, C<running>,
C<degraded>, or C<disabled> when not enabled), C<last_error> (a copy of
C<< { during, message } >>, or undef), a copy of C<stats>, and the
listener's own C<snapshot> (an empty hash when it has none). A listener
snapshot that dies or is not a hash reference reads as
C<< { status => 'unavailable', error => $message } >> and counts in
C<snapshot_failures>; it leaves C<last_error> and C<status> as they were,
since they describe the listener's own start, poll and reconnect. It never
dies itself, since C</metrics> and the admin console read it.

=head1 DIAGNOSTICS

None raised. Listener failures are caught and returned as C<degraded>; the
reason, or the first non-blank line (at most 300 characters) of the message
it died with, is kept in C<last_error> (in the C<listener> field's C<error>,
for a snapshot that died) and logged at C<warn> level through C<logger> as
C<realtime listener $during failed: $message> when the message differs from
the last one logged, or comes after a poll (a snapshot, for a snapshot
failure) that worked.

=head1 CONFIGURATION AND ENVIRONMENT

The module reads no environment itself. L<GPForum::Bootstrap::Core> builds it
from C<GPFORUM_REALTIME_LISTENER_ENABLED>,
C<GPFORUM_REALTIME_LISTENER_POLL_INTERVAL_SECONDS>,
C<GPFORUM_REALTIME_LISTENER_HEARTBEAT_INTERVAL_SECONDS> and
C<GPFORUM_REALTIME_LISTENER_RECONNECT_BACKOFF_SECONDS> through
L<GPForum::Config>, and, when the listener is enabled, calls L</start> before
each request is dispatched.

=head1 DEPENDENCIES

L<Const::Fast>,
L<Mojo::IOLoop>,
L<Scalar::Util>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The heartbeat only logs at debug level and counts; it does not probe the
listener. The reconnect backoff is fixed, not exponential. C<last_error>
keeps only the latest failure and is not cleared by a recovery: C<status>
says whether the listener is running again.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
