# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Worker::EventIdempotencyStore;

use strict;
use warnings;

use Const::Fast;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

# How long a claim is honoured before another worker may take it over. A
# worker killed between claiming and finishing would otherwise park its event
# forever, because the claim row it left behind looks exactly like one held by
# a worker that is still running.
const my $CLAIM_LEASE_SECONDS => 900;

has clock         => sub { return GPForum::Service::Clock->new; };
has lease_seconds => $CLAIM_LEASE_SECONDS;
has schema        => undef;

sub is_done ( $self, $key ) {
    my $row = $self->_find($key);
    return 0 if !$row;

    return defined $self->_column( $row, 'completed_at' ) ? 1 : 0;
}

# Returns true only for the worker that owns the event. The primary key does
# the excluding: the first insert wins and every later one conflicts, so two
# workers can no longer both pass this point and both run the side effect.
sub begin ( $self, $key, $event_id = undef ) {
    my ( $claimed, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            $self->_insert_claim( $key, $event_id );
            return 1;
        }
    );
    return 1 if $claimed;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_take_over($key);
}

sub mark_done ( $self, $key, $result ) {
    my $row = $self->_find($key);

    # Nothing claimed it, which means an older caller reached mark_done
    # without begin. Recording completion directly keeps that path idempotent.
    return $self->_insert_completed( $key, $result ) if !$row;

    $row->update( { completed_at => $self->clock->now_iso8601 } );

    return 1;
}

# Releasing the claim is what makes a failure retryable. Leaving the row would
# suppress every later attempt at the same event, turning one transient error
# into permanent silence.
sub mark_failed ( $self, $key, $error ) {
    my $row = $self->_find($key);
    return 1 if !$row;
    return 1 if defined $self->_column( $row, 'completed_at' );

    $row->delete;

    return 1;
}

# One statement, so the database is the arbiter of both the expiry and the
# race. Reading the row and then updating it would reintroduce exactly the
# check-then-act gap this class exists to close, and comparing timestamps in
# Perl would have to reconcile now_iso8601 with whatever the driver renders a
# timestamptz as.
sub _take_over ( $self, $key ) {
    my $updated = $self->_resultset->search_rs(
        {
            idempotency_key => $key,
            completed_at    => undef,
            created_at      => {
                q{<} =>
                  $self->clock->epoch_plus_iso8601( -$self->lease_seconds ),
            },
        }
    )->update( { created_at => $self->clock->now_iso8601 } );

    # Numeric, not boolean. DBI reports "no rows matched, but the statement
    # succeeded" as the string "0E0", which is true in boolean context: every
    # worker that lost the insert race would have been told it had taken the
    # claim over, and would have run the side effect anyway.
    return _affected($updated) > 0 ? 1 : 0;
}

sub _insert_claim ( $self, $key, $event_id ) {
    $self->_resultset->create(
        {
            completed_at    => undef,
            created_at      => $self->clock->now_iso8601,
            event_id        => _event_id( $key, { event_id => $event_id } ),
            idempotency_key => $key,
        }
    );

    return 1;
}

sub _insert_completed ( $self, $key, $result ) {
    my ( $inserted, $error ) = GPForum::Infrastructure::UniqueConflict->attempt(
        $self->schema,
        sub {
            my $now = $self->clock->now_iso8601;
            $self->_resultset->create(
                {
                    completed_at    => $now,
                    created_at      => $now,
                    event_id        => _event_id( $key, $result ),
                    idempotency_key => $key,
                }
            );
            return 1;
        }
    );
    return 1 if $inserted;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return 1;
}

sub _affected ($updated) {
    return 0 if !defined $updated;

    return $updated + 0;
}

sub _column ( $, $row, $name ) {
    return $row->{$name} if ref $row eq 'HASH';

    return $row->$name;
}

sub _find ( $self, $key ) {
    return $self->_resultset->find($key);
}

sub _resultset ($self) {
    return $self->schema->resultset('EventIdempotencyKey');
}

sub _event_id ( $key, $result ) {
    my $from_result = _result_event_id($result);
    if ( length $from_result ) {
        return $from_result;
    }

    return _key_event_id($key);
}

sub _result_event_id ($result) {
    if ( ref $result ne 'HASH' ) {
        return q{};
    }

    my $event_id = $result->{event_id};
    if ( !defined $event_id || !length $event_id ) {
        return q{};
    }

    return $event_id;
}

sub _key_event_id ($key) {
    my ($event_id) = $key =~ m/:([^:]+)\z/msx;
    if ( defined $event_id && length $event_id ) {
        return $event_id;
    }

    return $key;
}

1;
