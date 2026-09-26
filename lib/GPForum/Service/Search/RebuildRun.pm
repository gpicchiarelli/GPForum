# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Search::RebuildRun;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::CountedQuery;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Id;

our $VERSION = '0.001';

const my $AGGREGATE => 'search_rebuild';
const my $REQUESTED => 'search.rebuild_requested';
const my $COMPLETED => 'search.rebuild_completed';
const my @COUNTS    => qw(indexed pruned unchanged);

# The latest run's furthest step. Events carry whole-second timestamps, so a
# run's steps are ordered by their own counter, not by time.
const my $LATEST_SQL => join q{ },
  q{SELECT event_type, payload::text AS payload, created_at FROM event_log},
  q{WHERE aggregate_type = ? AND aggregate_id = (SELECT aggregate_id},
  q{FROM event_log WHERE aggregate_type = ?},
  q{ORDER BY created_at DESC, event_id DESC LIMIT 1)},
  q{ORDER BY (payload->>'step')::integer DESC LIMIT 1};

has id_service => sub { return GPForum::Infrastructure::Id->new; };
has indexer    => undef;
has recorder   => sub ($self) {
    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema => undef;

# A search rebuild the console asks for runs through the outbox, one batch
# per message: whatever runs the dispatcher runs it, a failed step is
# retried and dead-lettered like any other, and a large forum never holds
# the dispatcher for long. This records the first step's event, and its
# outbox message, in the caller's transaction.
sub request ( $self, $input ) {
    my $run_id = $self->id_service->uuid;
    $self->_record_once(
        $REQUESTED,
        {
            entity_type => $input->{entity_type} || 'all',
            run_id      => $run_id,
            step        => 0,
            totals      => { map { $_ => 0 } @COUNTS },
        },
        {
            actor_id       => $input->{actor_id},
            correlation_id => $input->{correlation_id},
        },
    );

    return { run_id => $run_id };
}

# One step, for the outbox's search handler: a batch, then the next step's
# event -- once, however often the message is retried -- or the run's
# completion with its totals.
sub step ( $self, $event ) {
    my $payload =
      ref $event->{domain_payload} eq 'HASH'
      ? $event->{domain_payload}
      : {};
    my $batch = $self->indexer->rebuild_batch(
        {
            after       => $payload->{after},
            entity_type => $payload->{entity_type},
            stage       => $payload->{stage},
        }
    );
    my %totals =
      map { $_ => ( $payload->{totals}{$_} // 0 ) + ( $batch->{$_} // 0 ) }
      @COUNTS;
    my %carried = (
        entity_type => $payload->{entity_type} || 'all',
        run_id      => $payload->{run_id},
        step        => ( $payload->{step} // 0 ) + 1,
        totals      => \%totals,
    );

    if ( my $next = $batch->{next} ) {
        $self->_record_once( $REQUESTED,
            { %carried, after => $next->{after}, stage => $next->{stage} },
            $event );
    }
    else {
        $self->_record_once( $COMPLETED, \%carried, $event );
    }

    return { %{$batch}, totals => \%totals };
}

# The latest run: the event it last recorded -- a step still to run, or its
# completion -- with its totals so far.
sub latest ($self) {
    my $row =
      GPForum::Infrastructure::CountedQuery->select_row( $self->schema,
        $LATEST_SQL, $AGGREGATE, $AGGREGATE );
    my $undefined;
    return $undefined if !$row;

    my $payload = $self->recorder->json->decode( $row->{payload} // '{}' );

    return {
        at          => $row->{created_at},
        completed   => $row->{event_type} eq $COMPLETED ? 1 : 0,
        entity_type => $payload->{entity_type},
        run_id      => $payload->{run_id},
        stage       => $payload->{stage},
        totals      => $payload->{totals} || {},
    };
}

sub handles ( $, $event_type ) {
    return ( $event_type // q{} ) eq $REQUESTED ? 1 : 0;
}

sub _record_once ( $self, $type, $payload, $cause ) {
    my $key = join q{:}, $type, $payload->{run_id},
      $payload->{stage} // 'start',
      $payload->{after} // 'start';
    return if $self->recorder->event_recorded($key);

    return $self->recorder->record_event(
        actor_id        => $cause->{actor_id},
        aggregate_id    => $payload->{run_id},
        aggregate_type  => $AGGREGATE,
        causation_id    => $cause->{event_id},
        correlation_id  => $cause->{correlation_id} || $self->id_service->uuid,
        event_type      => $type,
        idempotency_key => $key,
        payload         => $payload,
    );
}

1;

__END__

=head1 NAME

GPForum::Service::Search::RebuildRun - A search rebuild run through the outbox, one batch per message.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $run = GPForum::Service::Search::RebuildRun->new(
        indexer => $indexer,
        schema  => $schema,
    );
    $run->request( { actor_id => $admin_id } );   # from the console
    $run->step($event);                            # from the outbox handler
    my $latest = $run->latest;

=head1 DESCRIPTION

Splits L<GPForum::Service::Search::Indexer>'s rebuild into steps
(C<rebuild_batch>), each carried by a C<search.rebuild_requested> event and
its outbox message, and closed by C<search.rebuild_completed> with the run's
totals. Each next step is recorded once, keyed by the run, stage and cursor,
so a retried message never forks the run.

=head1 SUBROUTINES/METHODS

=head2 request

Starts a run; returns its id.

=head2 step

Runs one step for an outbox event and records the next, or the completion.

=head2 latest

The latest run's state, or nothing.

=head2 handles

True for the event type a step is carried by.

=head1 DIAGNOSTICS

Dies when the database does; the outbox retries the step.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Search::Indexer>,
L<GPForum::Infrastructure::EventRecorder>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A second run requested while one is going runs alongside it; both are
idempotent, so the forum is only indexed twice.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
