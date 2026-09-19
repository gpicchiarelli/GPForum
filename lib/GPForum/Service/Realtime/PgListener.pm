package GPForum::Service::Realtime::PgListener;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Realtime::EventEnvelope;
use GPForum::Service::Realtime::OutboxEventMapper;

our $VERSION = '0.001';

const my $DEFAULT_BATCH_LIMIT => 100;
const my $DEFAULT_SEEN_LIMIT  => 1000;
const my $DONE_STATUS         => 'done';

has batch_limit => $DEFAULT_BATCH_LIMIT;
has channel     => 'gpforum_domain_events';
has clock       => sub { return GPForum::Service::Clock->new; };
has event_contract =>
  sub { return GPForum::Service::Realtime::EventEnvelope->new; };
has hub             => undef;
has max_seen_events => $DEFAULT_SEEN_LIMIT;
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
        broadcast              => 0,
        broadcast_failures     => 0,
        delivered              => 0,
        degraded               => 0,
        duplicates             => 0,
        failed                 => 0,
        invalid_payloads       => 0,
        listen_notify_received => 0,
        listener_lag           => 0,
        malformed              => 0,
        malformed_payloads     => 0,
        outbox_poll_received   => 0,
        reconnect_count        => 0,
    };
};

sub start {
    my ($self) = @_;

    my $dbh = $self->_dbh;
    if ( !$dbh ) {
        return $self->_start_outbox_polling('listen_unavailable');
    }

    my $ok = eval {
        $dbh->do( 'LISTEN ' . $self->channel );
        return 1;
    };
    return $self->_start_outbox_polling('listen_failed') if !$ok;

    $self->status('listening');

    return { ok => 1, status => $self->status, channel => $self->channel };
}

sub stop {
    my ($self) = @_;

    my $dbh = $self->_dbh;
    if ($dbh) {
        my $unlistened = eval {
            $dbh->do( 'UNLISTEN ' . $self->channel );
            return 1;
        };
        if ( !$unlistened ) {
            $self->stats->{degraded} += 1;
        }
    }
    $self->status('stopped');

    return { ok => 1, status => $self->status };
}

sub poll_once {
    my ($self) = @_;

    my $notify = $self->_poll_listen_notify;
    my $outbox = $self->_poll_outbox;
    if ( !$notify->{available} && !$outbox->{available} ) {
        return $self->_degraded('poll_unavailable');
    }

    return _combined_summary( $notify, $outbox );
}

sub _poll_listen_notify {
    my ($self) = @_;

    my $dbh = $self->_dbh;
    return _unavailable_summary() if !$dbh || !$dbh->can('pg_notifies');

    my %summary = (
        available  => 1,
        delivered  => 0,
        failed     => 0,
        invalid    => 0,
        received   => 0,
        duplicates => 0,
    );

    for ( 1 .. $self->batch_limit ) {
        my $notification = $dbh->pg_notifies;
        last if !$notification;

        $self->_poll_notification( \%summary, $notification );
    }

    return \%summary;
}

sub _poll_notification {
    my ( $self, $summary, $notification ) = @_;

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

sub _poll_outbox {
    my ($self) = @_;

    return _unavailable_summary() if !$self->outbox_poll_enabled;

    my @messages = $self->_outbox_messages;
    return _unavailable_summary() if !@messages && !$self->_outbox_available;

    my %summary = (
        available  => 1,
        delivered  => 0,
        failed     => 0,
        invalid    => 0,
        received   => 0,
        duplicates => 0,
    );

    for my $message (@messages) {
        $self->_poll_outbox_message( \%summary, $message );
        $self->_advance_outbox_poll_cursor($message);
    }

    return \%summary;
}

sub _poll_outbox_message {
    my ( $self, $summary, $message ) = @_;

    my @events =
      $self->_outbox_event_mapper->events_for_payload(
        $message->get_column('payload') );
    for my $event (@events) {
        $summary->{received} += 1;
        $self->stats->{outbox_poll_received} += 1;
        $self->_deliver_event( $summary, $event );
    }

    return;
}

sub _deliver_event {
    my ( $self, $summary, $event ) = @_;

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

sub _record_broadcast_result {
    my ( $self, $summary, $broadcast ) = @_;

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

sub _record_malformed {
    my ( $self, $summary ) = @_;

    $summary->{invalid}                += 1;
    $self->stats->{invalid_payloads}   += 1;
    $self->stats->{malformed}          += 1;
    $self->stats->{malformed_payloads} += 1;

    return;
}

sub reconnect {
    my ($self) = @_;

    $self->stats->{reconnect_count} += 1;
    $self->stop;

    return $self->start;
}

sub snapshot {
    my ($self) = @_;

    return {
        %{ $self->stats },
        channel => $self->channel,
        status  => $self->status,
    };
}

sub _broadcast_event {
    my ( $self, $event ) = @_;

    return { ok => 0, reason => 'hub_unavailable' } if !$self->hub;

    return $self->hub->broadcast_event($event);
}

sub _degraded {
    my ( $self, $reason ) = @_;

    $self->stats->{degraded} += 1;
    $self->status('degraded');

    return {
        ok       => 0,
        degraded => 1,
        reason   => $reason,
        status   => $self->status,
    };
}

sub _start_outbox_polling {
    my ( $self, $reason ) = @_;

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

sub _dbh {
    my ($self) = @_;

    return if !$self->schema;

    return eval { return $self->schema->storage->dbh; };
}

sub _outbox_available {
    my ($self) = @_;

    return if !$self->schema || !$self->schema->can('resultset');

    my $resultset = eval { return $self->schema->resultset('OutboxMessage'); };

    return $resultset ? 1 : 0;
}

sub _outbox_messages {
    my ($self) = @_;

    return if !$self->_outbox_available;

    my $search = eval {
        return $self->schema->resultset('OutboxMessage')->search(
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
    };
    return if !$search;

    return _search_rows($search);
}

sub _outbox_event_mapper {
    my ($self) = @_;

    my $mapper = $self->outbox_event_mapper;
    if ( $mapper->can('schema') && !$mapper->schema ) {
        $mapper->schema( $self->schema );
    }

    return $mapper;
}

sub _outbox_poll_query {
    my ($self) = @_;

    my $cursor = $self->outbox_poll_cursor;
    return { status => $DONE_STATUS } if !$cursor;

    return [
        {
            status          => $DONE_STATUS,
            next_attempt_at => { q{>} => $cursor->{next_attempt_at} },
        },
        {
            status          => $DONE_STATUS,
            next_attempt_at => $cursor->{next_attempt_at},
            created_at      => { q{>} => $cursor->{created_at} },
        },
        {
            status          => $DONE_STATUS,
            next_attempt_at => $cursor->{next_attempt_at},
            created_at      => $cursor->{created_at},
            outbox_id       => { q{>} => $cursor->{outbox_id} },
        },
    ];
}

sub _advance_outbox_poll_cursor {
    my ( $self, $message ) = @_;

    $self->outbox_poll_cursor( _message_cursor($message) );

    return;
}

sub _seen_or_mark {
    my ( $self, $event_id ) = @_;

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

sub _notification_payload {
    my ($notification) = @_;

    return $notification->[2]       if ref $notification eq 'ARRAY';
    return $notification->{payload} if ref $notification eq 'HASH';

    return $notification;
}

sub _search_rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _message_cursor {
    my ($message) = @_;

    return {
        next_attempt_at => _column_or_empty( $message, 'next_attempt_at' ),
        created_at      => _column_or_empty( $message, 'created_at' ),
        outbox_id       => _column_or_empty( $message, 'outbox_id' ),
    };
}

sub _column_or_empty {
    my ( $row, $column ) = @_;

    my $value = $row->get_column($column);

    return defined $value ? $value : q{};
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

sub _combined_summary {
    my ( $notify, $outbox ) = @_;

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
