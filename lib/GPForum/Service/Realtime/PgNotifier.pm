# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::PgNotifier;

use Mojo::Base -base, -signatures;
use v5.40;

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
    return undef if !$self->schema;

    return eval { return $self->schema->storage->dbh; };
}

1;

__END__

=head1 NAME

GPForum::Service::Realtime::PgNotifier - Publishes a realtime event to the other nodes through PostgreSQL NOTIFY.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $notifier = GPForum::Service::Realtime::PgNotifier->new(
        schema => $schema,
    );
    my $result = $notifier->notify($event);
    # { ok => 1, channel => 'gpforum_domain_events', bytes => ... }
    my $stats = $notifier->snapshot;

=head1 DESCRIPTION

The sending half of the realtime fan-out between nodes; the receiving half
is L<GPForum::Service::Realtime::PgListener>, which listens on the same
C<channel> (C<gpforum_domain_events> by default). An event is first checked
and serialized by the C<event_contract>, then sent with
C<SELECT pg_notify(?, ?)> on the schema's database handle.

A failure never dies: it is returned and counted in C<stats>, so that the
caller (the outbox transport or the notification dispatcher) can carry on.
An event the contract refuses is counted as C<rejected>; a missing handle
as C<degraded>; a failed C<pg_notify> as C<notify_failures>; a sent event
as C<notified>. The counters live in this object, so they are per process.

The notification goes out on the schema's own handle, so when the caller
is inside a transaction PostgreSQL delivers it at commit, and drops it on
rollback.

=head1 SUBROUTINES/METHODS

=head2 notify

Takes an event hash reference. Returns C<< { ok => 1, channel, bytes } >>,
C<bytes> being the payload size the contract measured. On failure returns
C<ok> 0 with a C<failure_type> and a C<reason>: C<serialization> with the
contract's reason (for example C<payload_too_large>) when the event is
refused; C<transport> with C<< degraded => 1 >> and C<notify_unavailable>
when there is no schema or asking it for a handle fails; C<transport> with
C<< degraded => 1 >> and C<notify_failed> when the C<pg_notify> statement
dies.

=head2 snapshot

Takes no arguments. Returns a copy of the counters C<degraded>,
C<notify_failures>, C<notified> and C<rejected>, with the C<channel> name.

=head1 DIAGNOSTICS

None raised; see C<notify> for the failures it returns.

=head1 CONFIGURATION AND ENVIRONMENT

None read directly. The C<channel> attribute must match the listener's.

=head1 DEPENDENCIES

L<Mojo::Base>, L<GPForum::Service::Realtime::EventEnvelope>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
