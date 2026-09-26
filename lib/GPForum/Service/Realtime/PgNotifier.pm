# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::PgNotifier;

use strict;
use warnings;

use Mojo::Base -base, -signatures;

use GPForum::Service::Realtime::EventEnvelope;

our $VERSION = '0.001';

has channel => 'gpforum_domain_events';
has event_contract =>
  sub { return GPForum::Service::Realtime::EventEnvelope->new; };
has schema => undef;
has stats  => sub {
    return {
        degraded        => 0,
        notify_failures => 0,
        notified        => 0,
        rejected        => 0,
    };
};

sub notify ( $self, $event ) {
    my $serialized = $self->event_contract->serialize($event);
    if ( !$serialized->{ok} ) {
        $self->stats->{rejected} += 1;
        return {
            ok           => 0,
            failure_type => 'serialization',
            reason       => $serialized->{reason},
        };
    }

    my $dbh = $self->_dbh;
    if ( !$dbh ) {
        $self->stats->{degraded} += 1;
        return {
            ok           => 0,
            degraded     => 1,
            failure_type => 'transport',
            reason       => 'notify_unavailable',
        };
    }

    my $ok = eval {
        $dbh->do( 'SELECT pg_notify(?, ?)',
            undef, $self->channel, $serialized->{json} );
        return 1;
    };

    if ( !$ok ) {
        $self->stats->{notify_failures} += 1;
        return {
            ok           => 0,
            degraded     => 1,
            failure_type => 'transport',
            reason       => 'notify_failed',
        };
    }

    $self->stats->{notified} += 1;

    return {
        ok      => 1,
        channel => $self->channel,
        bytes   => $serialized->{bytes},
    };
}

sub snapshot ($self) {
    return { %{ $self->stats }, channel => $self->channel };
}

sub _dbh ($self) {
    my $undefined;
    return $undefined if !$self->schema;

    return eval { return $self->schema->storage->dbh; };
}

1;
