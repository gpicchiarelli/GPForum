package GPForum::Service::Realtime::PgListener;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Realtime::EventEnvelope;

our $VERSION = '0.001';

const my $DEFAULT_BATCH_LIMIT => 100;
const my $DEFAULT_SEEN_LIMIT  => 1000;

has batch_limit => $DEFAULT_BATCH_LIMIT;
has channel     => 'gpforum_realtime_events';
has clock       => sub { return GPForum::Service::Clock->new; };
has event_contract =>
  sub { return GPForum::Service::Realtime::EventEnvelope->new; };
has hub             => undef;
has max_seen_events => $DEFAULT_SEEN_LIMIT;
has seen_event_ids  => sub { return {}; };
has seen_order      => sub { return []; };
has schema          => undef;
has status          => 'stopped';
has stats           => sub {
    return {
        broadcast_failures => 0,
        delivered          => 0,
        degraded           => 0,
        duplicates         => 0,
        invalid_payloads   => 0,
        listener_lag       => 0,
        malformed_payloads => 0,
        reconnect_count    => 0,
    };
};

sub start {
    my ($self) = @_;

    my $dbh = $self->_dbh;
    if ( !$dbh ) {
        return $self->_degraded('listen_unavailable');
    }

    my $ok = eval {
        $dbh->do( 'LISTEN ' . $self->channel );
        return 1;
    };
    return $self->_degraded('listen_failed') if !$ok;

    $self->status('listening');

    return { ok => 1, status => $self->status, channel => $self->channel };
}

sub stop {
    my ($self) = @_;

    my $dbh = $self->_dbh;
    if ($dbh) {
        eval { $dbh->do( 'UNLISTEN ' . $self->channel ); };
    }
    $self->status('stopped');

    return { ok => 1, status => $self->status };
}

sub poll_once {
    my ($self) = @_;

    my $dbh = $self->_dbh;
    if ( !$dbh || !$dbh->can('pg_notifies') ) {
        return $self->_degraded('poll_unavailable');
    }

    my %summary = (
        ok         => 1,
        delivered  => 0,
        invalid    => 0,
        received   => 0,
        duplicates => 0,
    );

    for ( 1 .. $self->batch_limit ) {
        my $notification = $dbh->pg_notifies;
        last if !$notification;

        $summary{received} += 1;
        my $payload = _notification_payload($notification);
        my $decoded = $self->event_contract->deserialize($payload);
        if ( !$decoded->{ok} ) {
            $summary{invalid} += 1;
            $self->stats->{invalid_payloads} += 1;
            next;
        }
        if ( $self->_seen_or_mark( $decoded->{event}{event_id} ) ) {
            $summary{duplicates} += 1;
            $self->stats->{duplicates} += 1;
            next;
        }

        my $broadcast = $self->_broadcast_event( $decoded->{event} );
        if ( $broadcast->{ok} ) {
            $summary{delivered}       += $broadcast->{delivered} || 0;
            $self->stats->{delivered} += $broadcast->{delivered} || 0;
        }
        else {
            $self->stats->{broadcast_failures} += 1;
        }
    }

    return \%summary;
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

sub _dbh {
    my ($self) = @_;

    return if !$self->schema;

    return eval { return $self->schema->storage->dbh; };
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

1;
