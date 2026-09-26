# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::PgListener;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;
use POSIX qw(strftime);

use GPForum::Infrastructure::PgNotifications;
use GPForum::Service::Realtime::EventEnvelope;
use GPForum::Service::Realtime::OutboxEventMapper;

our $VERSION = '0.001';

const my $DEFAULT_BATCH_LIMIT => 100;
const my $DEFAULT_SEEN_LIMIT  => 1000;
const my $DONE_STATUS         => 'done';
const my $MICROSECONDS        => 1_000_000;

# A done row is read only once it is this old by the database's clock. The
# dispatcher stamps next_attempt_at before its UPDATE commits, so a cursor
# that ran up to the newest stamp could pass a row that committed a moment
# later with an older one, and never read it. The SQL says the same five
# seconds, so the poll needs no separate query for the clock.
const my $SETTLE_SECONDS => 5;
const my $SETTLED_SQL    => q{statement_timestamp() - interval '5 seconds'};

# The head of the outbox as a cursor: no row stamped at the seed instant
# sorts after these, so only rows stamped later are read.
const my $HEAD_CREATED_AT => 'infinity';
const my $HEAD_OUTBOX_ID  => 'ffffffff-ffff-ffff-ffff-ffffffffffff';

has batch_limit => $DEFAULT_BATCH_LIMIT;
has channel     => 'gpforum_domain_events';

# The database's clock, as a code ref returning epoch seconds. Left undef,
# PostgreSQL's own statement_timestamp() is used; tests set it because the
# in-memory resultsets cannot evaluate SQL.
has db_now => undef;
has event_contract =>
  sub { return GPForum::Service::Realtime::EventEnvelope->new; };
has hub             => undef;
has max_seen_events => $DEFAULT_SEEN_LIMIT;

# The process's one queue for its handle, shared with the cache
# invalidation bus (Bootstrap injects it).
has notifications => sub ($self) {
    return GPForum::Infrastructure::PgNotifications->new(
        schema => $self->schema );
};
has outbox_event_mapper =>
  sub { return GPForum::Service::Realtime::OutboxEventMapper->new; };
has outbox_poll_enabled => 1;
has outbox_poll_cursor  => undef;
has seen_event_ids      => sub { return {}; };
has seen_order          => sub { return []; };
has schema              => undef;
has status              => 'stopped';
has stats               => sub {
    return {
        badge_snapshots        => 0,
        broadcast              => 0,
        broadcast_failures     => 0,
        delivered              => 0,
        degraded               => 0,
        duplicates             => 0,
        failed                 => 0,
        gaps                   => 0,
        invalid_payloads       => 0,
        listen_notify_received => 0,
        malformed              => 0,
        malformed_payloads     => 0,
        outbox_poll_received   => 0,
        reconnect_count        => 0,
    };
};

sub start ($self) {
    if ( !$self->notifications->listen_to( $self->channel ) ) {
        return $self->_start_outbox_polling('listen_unavailable');
    }

    $self->status('listening');

    return { ok => 1, status => $self->status, channel => $self->channel };
}

sub stop ($self) {
    if ( !$self->notifications->unlisten( $self->channel ) ) {
        $self->stats->{degraded} += 1;
    }
    $self->status('stopped');

    return { ok => 1, status => $self->status };
}

sub poll_once ($self) {
    my $notify = $self->_poll_listen_notify;
    my $outbox = $self->_poll_outbox;
    if ( !$notify->{available} && !$outbox->{available} ) {
        return $self->_degraded('poll_unavailable');
    }

    return _combined_summary( $notify, $outbox );
}

sub _poll_listen_notify ($self) {
    my $taken = $self->notifications->take( $self->channel );
    $self->_note_listen_state;

    my %summary = (
        available  => $taken->{available},
        delivered  => 0,
        failed     => 0,
        invalid    => 0,
        received   => 0,
        duplicates => 0,
    );

    for my $notification ( @{ $taken->{notifications} } ) {
        $self->_poll_notification( \%summary, $notification );
    }

    # Badges are absolute counts, so the ones lost in a gap are rebuilt by
    # sending each local subscriber its count again. Thread and moderation
    # hints lost in it are read back by the outbox backstop.
    if ( $taken->{gap} ) {
        $self->stats->{gaps} += 1;
        $self->_resend_badges;
    }

    return \%summary;
}

sub _note_listen_state ($self) {
    return if $self->status eq 'stopped';

    $self->status(
        $self->notifications->listening( $self->channel )
        ? 'listening'
        : 'polling'
    );

    return;
}

sub _resend_badges ($self) {
    return if !$self->hub || !$self->hub->can('resend_badge_snapshots');

    $self->stats->{badge_snapshots} += $self->hub->resend_badge_snapshots;

    return;
}

sub _poll_notification ( $self, $summary, $notification ) {
    $summary->{received} += 1;
    $self->stats->{listen_notify_received} += 1;

    my $decoded =
      $self->event_contract->deserialize(
        _notification_payload($notification) );
    if ( !$decoded->{ok} ) {
        $self->_record_malformed($summary);
        return;
    }

    $self->_deliver_event( $summary, $decoded->{event} );

    return;
}

# The backstop for NOTIFYs that never arrived. ADR 0067: it runs for this
# process's sockets, so with none there is nothing to poll for; every worker
# on every node polling regardless made PostgreSQL's load grow with the
# processes, not with the connections. The cursor goes with the last socket,
# and the next one starts from the head.
sub _poll_outbox ($self) {
    if ( !$self->outbox_poll_enabled || !$self->_outbox_available ) {
        return _unavailable_summary();
    }
    if ( !$self->_has_local_connections ) {
        $self->outbox_poll_cursor(undef);
        return _available_summary();
    }

    # A new cursor starts at the head, not at the oldest retained row: a
    # worker recycled or deployed replayed up to seven days of events into
    # live sockets, and was minutes behind the NOTIFYs it was backing up.
    if ( !$self->outbox_poll_cursor ) {
        my $head = $self->_settled_instant;
        return _unavailable_summary() if !defined $head;

        $self->outbox_poll_cursor( _head_cursor($head) );
        return _available_summary();
    }

    my %summary = %{ _available_summary() };
    for my $message ( $self->_outbox_messages ) {
        $self->_poll_outbox_message( \%summary, $message );
        $self->_advance_outbox_poll_cursor($message);
    }

    return \%summary;
}

sub _has_local_connections ($self) {
    return 0 if !$self->hub || !$self->hub->can('connection_count');

    return $self->hub->connection_count > 0 ? 1 : 0;
}

sub _poll_outbox_message ( $self, $summary, $message ) {
    my @events =
      $self->outbox_event_mapper->events_for_payload(
        _message_payload($message) );
    for my $event (@events) {
        $summary->{received} += 1;
        $self->stats->{outbox_poll_received} += 1;
        $self->_deliver_event( $summary, $event );
    }

    return;
}

sub _deliver_event ( $self, $summary, $event ) {
    if ( $self->_seen_or_mark( $event->{event_id} ) ) {
        $summary->{duplicates} += 1;
        $self->stats->{duplicates} += 1;
        return;
    }

    my $broadcast = $self->_broadcast_event($event);
    $self->stats->{broadcast} += 1;

    $self->_record_broadcast_result( $summary, $broadcast );

    return;
}

sub _record_broadcast_result ( $self, $summary, $broadcast ) {
    if ( $broadcast->{ok} ) {
        my $delivered = $broadcast->{delivered} || 0;
        my $failed    = $broadcast->{failed}    || 0;

        $summary->{delivered}     += $delivered;
        $self->stats->{delivered} += $delivered;
        $summary->{failed}        += $failed;
        $self->stats->{failed}    += $failed;
        return;
    }

    $summary->{failed}                 += 1;
    $self->stats->{failed}             += 1;
    $self->stats->{broadcast_failures} += 1;

    return;
}

sub _record_malformed ( $self, $summary ) {
    $summary->{invalid}                += 1;
    $self->stats->{invalid_payloads}   += 1;
    $self->stats->{malformed}          += 1;
    $self->stats->{malformed_payloads} += 1;

    return;
}

# The LISTEN stays registered and the cursor stays where it was: the queue
# re-issues the LISTEN on whatever backend the handle has now and reports
# the gap, and the backstop reads what was missed during the outage.
sub reconnect ($self) {
    $self->stats->{reconnect_count} += 1;

    return $self->start;
}

sub snapshot ($self) {
    return {
        %{ $self->stats },
        channel       => $self->channel,
        notifications => $self->notifications->snapshot,
        status        => $self->status,
    };
}

sub _broadcast_event ( $self, $event ) {
    return { ok => 0, reason => 'hub_unavailable' } if !$self->hub;

    return $self->hub->broadcast_event($event);
}

sub _degraded ( $self, $reason ) {
    $self->stats->{degraded} += 1;
    $self->status('degraded');

    return {
        ok       => 0,
        degraded => 1,
        reason   => $reason,
        status   => $self->status,
    };
}

sub _start_outbox_polling ( $self, $reason ) {
    return $self->_degraded($reason) if !$self->_outbox_available;

    $self->stats->{degraded} += 1;
    $self->status('polling');

    return {
        ok       => 1,
        degraded => 1,
        reason   => $reason,
        status   => $self->status,
        channel  => $self->channel,
    };
}

sub _outbox_available ($self) {
    my $undefined;
    return $undefined if !$self->schema || !$self->schema->can('resultset');

    my $resultset = eval { return $self->schema->resultset('OutboxMessage'); };

    return $resultset ? 1 : 0;
}

sub _outbox_messages ($self) {

    # Callers iterate the result, so every early exit must yield an empty
    # list. A single undef would become one undefined message row.
    my $search = eval { return $self->outbox_poll_resultset };
    return () if !$search;

    return _search_rows($search);
}

# The next batch the backstop reads after its cursor. Public so the tests
# see the SQL that runs.
sub outbox_poll_resultset ($self) {
    return $self->schema->resultset('OutboxMessage')->search_rs(
        $self->_outbox_poll_query,
        {
            order_by => [
                { -asc => 'next_attempt_at' },
                { -asc => 'created_at' },
                { -asc => 'outbox_id' },
            ],
            rows => $self->batch_limit,
        },
    );
}

# Rows past the cursor that have settled, as a keyset over (next_attempt_at,
# created_at, outbox_id). The OR alone is a filter PostgreSQL cannot start an
# index scan from: with the cursor at the head of a week of done rows, every
# poll walked the whole index up to it. The bound it implies on
# next_attempt_at, with the settle bound, is the index range; the OR only
# resolves ties on the cursor's own stamp (see Infrastructure::Keyset).
sub _outbox_poll_query ($self) {
    my $cursor = $self->outbox_poll_cursor;
    my $stamp  = $cursor->{next_attempt_at};

    return {
        status          => $DONE_STATUS,
        next_attempt_at => {
            q{>=} => $stamp,
            q{<=} => $self->_settled_bound,
        },
        -or => [
            { next_attempt_at => { q{>} => $stamp } },
            {
                next_attempt_at => $stamp,
                created_at      => { q{>} => $cursor->{created_at} },
            },
            {
                next_attempt_at => $stamp,
                created_at      => $cursor->{created_at},
                outbox_id       => { q{>} => $cursor->{outbox_id} },
            },
        ],
    };
}

# The database's clock, not this host's: dispatchers on other hosts stamp
# the rows, and only the database orders them.
sub _settled_bound ($self) {
    return _iso8601( $self->db_now->() - $SETTLE_SECONDS ) if $self->db_now;

    return \$SETTLED_SQL;
}

# The same instant as a value, for the head cursor: one query when a cursor
# is seeded, none per poll. Undef when the database cannot be asked.
sub _settled_instant ($self) {
    return _iso8601( $self->db_now->() - $SETTLE_SECONDS ) if $self->db_now;

    return eval {
        return $self->schema->storage->dbh_do(
            sub ( $, $dbh ) {
                my ($instant) =
                  $dbh->selectrow_array( 'SELECT ' . $SETTLED_SQL );
                return $instant;
            }
        );
    };
}

sub _advance_outbox_poll_cursor ( $self, $message ) {
    $self->outbox_poll_cursor( _message_cursor($message) );

    return;
}

sub _seen_or_mark ( $self, $event_id ) {
    return 0 if !defined $event_id || !length $event_id;
    return 1 if $self->seen_event_ids->{$event_id};

    $self->seen_event_ids->{$event_id} = 1;
    push @{ $self->seen_order }, $event_id;

    while ( @{ $self->seen_order } > $self->max_seen_events ) {
        my $oldest = shift @{ $self->seen_order };
        delete $self->seen_event_ids->{$oldest};
    }

    return 0;
}

sub _notification_payload ($notification) {
    return $notification->[2]       if ref $notification eq 'ARRAY';
    return $notification->{payload} if ref $notification eq 'HASH';

    return $notification;
}

sub _search_rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

# The payload as data. get_column returns a jsonb column as its text, which
# the payload contract reads as an empty event: the backstop mapped every row
# it read from PostgreSQL to nothing. Only the tests' in-memory rows, which
# hold a hash, ever reached a socket.
sub _message_payload ($message) {
    return $message->get_inflated_column('payload')
      if $message->can('get_inflated_column');

    return $message->get_column('payload');
}

sub _head_cursor ($instant) {
    return {
        next_attempt_at => $instant,
        created_at      => $HEAD_CREATED_AT,
        outbox_id       => $HEAD_OUTBOX_ID,
    };
}

sub _message_cursor ($message) {
    return {
        next_attempt_at => _column_or_empty( $message, 'next_attempt_at' ),
        created_at      => _column_or_empty( $message, 'created_at' ),
        outbox_id       => _column_or_empty( $message, 'outbox_id' ),
    };
}

sub _column_or_empty ( $row, $column ) {
    my $value = $row->get_column($column);

    return defined $value ? $value : q{};
}

# UTC, to the microsecond PostgreSQL keeps; the fraction is left out when
# there is none.
sub _iso8601 ($epoch) {
    my $seconds  = int $epoch;
    my $fraction = int( ( $epoch - $seconds ) * $MICROSECONDS );
    my $text     = strftime( '%Y-%m-%dT%H:%M:%S', gmtime $seconds );

    return $fraction ? sprintf( '%s.%06dZ', $text, $fraction ) : $text . 'Z';
}

sub _available_summary {
    return { %{ _unavailable_summary() }, available => 1 };
}

sub _unavailable_summary {
    return {
        available  => 0,
        delivered  => 0,
        failed     => 0,
        invalid    => 0,
        received   => 0,
        duplicates => 0,
    };
}

sub _combined_summary ( $notify, $outbox ) {
    return {
        ok         => 1,
        delivered  => $notify->{delivered} + $outbox->{delivered},
        failed     => $notify->{failed} + $outbox->{failed},
        invalid    => $notify->{invalid} + $outbox->{invalid},
        received   => $notify->{received} + $outbox->{received},
        duplicates => $notify->{duplicates} + $outbox->{duplicates},
    };
}

1;

__END__

=head1 NAME

GPForum::Service::Realtime::PgListener - Delivers domain events from
PostgreSQL to this process's websocket subscribers.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $listener = GPForum::Service::Realtime::PgListener->new(
        hub           => $hub,
        notifications => $pg_notifications,
        schema        => $schema,
    );

    $listener->start;
    $listener->poll_once;    # from the supervisor's timer

=head1 DESCRIPTION

Every web process runs one listener, and each fans out only to its own
sockets (ADR 0006, 0055). There is no shared presence or subscription
registry.

Events arrive two ways. The fast path is LISTEN/NOTIFY on
C<gpforum_domain_events>, read from the process's shared notification queue
(L<GPForum::Infrastructure::PgNotifications>), so the cache invalidation bus
on the same handle keeps its own notifications. The backstop reads done
outbox rows through a cursor, for NOTIFYs that never arrived; it runs only
while this process has sockets, starts at the head of the outbox, and reads a
row only once it has settled for five seconds by the database's clock.
Duplicate event ids from the two paths are suppressed with a bounded memory.

When the queue reports a gap -- the handle's backend was replaced, or the
queue overflowed -- the listener sends every local notifications subscriber
its unread count again.

=head1 SUBROUTINES/METHODS

=head2 start

Issues the LISTEN. Returns C<status =E<gt> 'polling'> and C<degraded> when it
could not, and the outbox backstop is the only path.

=head2 stop

Issues the UNLISTEN.

=head2 poll_once

Delivers what arrived on both paths. Fails only when neither is available.

=head2 reconnect

Starts again without dropping the channel or the cursor.

=head2 outbox_poll_resultset

The resultset of the backstop's next batch after its cursor: settled done
rows in (next_attempt_at, created_at, outbox_id) order, bounded on
next_attempt_at from both sides so the index range starts at the cursor.

=head2 snapshot

Counters, status and the notification queue's state, for C</metrics>.

=head1 DIAGNOSTICS

Never throws. Malformed payloads, duplicates, failed broadcasts and gaps are
counted in C<stats>.

=head1 CONFIGURATION AND ENVIRONMENT

Started by L<GPForum::Service::Realtime::ListenerSupervisor> when
C<GPFORUM_REALTIME_LISTENER_ENABLED> is set. The settle window (5 seconds)
and batch size are constants.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::PgNotifications>,
L<GPForum::Service::Realtime::EventEnvelope>,
L<GPForum::Service::Realtime::OutboxEventMapper>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

There is no replay log. A client that reconnects refetches canonical state;
the backstop only covers NOTIFYs lost while this process had sockets.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
