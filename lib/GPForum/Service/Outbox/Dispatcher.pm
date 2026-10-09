# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Outbox::Dispatcher;

use Const::Fast;
use GPForum::Infrastructure::Storage;
use GPForum::Service::Clock;
use GPForum::Service::Outbox::ClaimedMessage;
use GPForum::Service::Outbox::ClaimQuery;
use GPForum::Service::Outbox::DeadLetterRecorder;
use GPForum::Service::Outbox::FailureType;
use GPForum::Service::Outbox::Retry;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT        => 100;
const my $DEFAULT_MAX_ATTEMPTS => 5;
const my $PENDING_STATUS       => 'pending';
const my $FAILED_STATUS        => 'failed';
const my $RUNNING_STATUS       => 'running';
const my $DONE_STATUS          => 'done';
const my $CANCELLED_STATUS     => 'cancelled';
const my $GENERIC_ERROR_CLASS  => 'error';
const my $OUTBOX_TABLE         => 'outbox_messages';

# The condition every write after the claim carries: the message is still
# this worker's. Another worker's claim rewrites locked_by while it holds the
# row's lock, so an UPDATE that still finds this worker there owns the
# message, and one that finds another, or a finished row, writes nothing --
# and RETURNING says which of the two happened.
const my $OWNED_WHERE =>
  'WHERE outbox_id = ? AND locked_by = ? AND status = ? RETURNING outbox_id';

__PACKAGE__->requires(qw(schema transport));
has clock         => sub { return GPForum::Service::Clock->new; };
has worker_id     => 'worker';
has max_attempts  => $DEFAULT_MAX_ATTEMPTS;
has id_service    => undef; # optional: the dead-letter recorder's default
has logger        => undef; # optional: lost claims are only counted without one
has claim_query   => sub { return GPForum::Service::Outbox::ClaimQuery->new; };
has failure_types => sub { return GPForum::Service::Outbox::FailureType->new; };
has retry         => sub {
    my ($self) = @_;

    return GPForum::Service::Outbox::Retry->new(
        max_attempts => $self->max_attempts, );
};
has dead_letter_recorder => sub {
    my ($self) = @_;

    return GPForum::Service::Outbox::DeadLetterRecorder->new(
        $self->_dead_letter_recorder_args, );
};

# A batch is claimed for Retry's lock_seconds, and a slow batch used to
# outlive that claim: the messages were acknowledged together at the end, so
# once the lease ran out a second worker claimed and delivered the rest of
# the batch, and this one delivered it again. Each message is now handled on
# its own: its claim renewed just before it is dispatched, its outcome
# written as soon as it is known, and every one of those writes made only
# while the message is still this worker's.
sub dispatch_pending ( $self, $limit ) {
    my @messages = $self->claim_ready_batch( $limit || $DEFAULT_LIMIT );
    my %summary  = (
        acknowledged  => 0,
        dead_lettered => 0,
        dispatched    => 0,
        failed        => 0,
        lost          => 0,
        selected      => scalar @messages,
    );

    for my $message (@messages) {
        for my $counter ( $self->_handle($message) ) {
            $summary{$counter} += 1;
        }
    }

    return \%summary;
}

sub claim_ready_batch ( $self, $limit ) {
    if ( $self->_supports_postgresql_claim ) {
        return $self->_claim_ready_batch_postgresql($limit);
    }

    return $self->_claim_ready_batch_resultset($limit);
}

sub _claim_ready_batch_postgresql ( $self, $limit ) {
    my $bind = $self->claim_query->bind_values(
        {
            limit        => $limit,
            locked_until =>
              $self->clock->epoch_plus_iso8601( $self->retry->lock_seconds ),
            now       => $self->clock->now_iso8601,
            worker_id => $self->worker_id,
        }
    );
    my $messages = $self->schema->txn_do(
        sub {
            my $dbh = GPForum::Infrastructure::Storage->dbh_of( $self->schema );
            my $rows = $dbh->selectall_arrayref(
                $self->claim_query->sql,
                { Slice => {} },
                @{$bind}
            );
            return [ map { $self->_claimed_message_for_row($_) } @{$rows} ];
        }
    );

    return @{$messages};
}

sub _claim_ready_batch_resultset ( $self, $limit ) {
    my $now      = $self->clock->now_iso8601;
    my @messages = _search_rows(
        $self->schema->resultset('OutboxMessage')->search_rs(
            [
                {
                    status => { -in => [ $PENDING_STATUS, $FAILED_STATUS ] },
                    next_attempt_at => { '<=' => $now },
                },
                {
                    status       => $RUNNING_STATUS,
                    locked_until => { '<=' => $now },
                },
            ],
            {
                order_by => [
                    { -asc => 'next_attempt_at' },
                    { -asc => 'created_at' },
                    { -asc => 'outbox_id' },
                ],
                rows => $limit,
            }
        )
    );

    for my $message (@messages) {
        $self->_mark_running($message);
    }

    return @messages;
}

sub _supports_postgresql_claim ($self) {
    if ( !$self->schema->can('txn_do') ) {
        return undef;
    }

    my $dbh = GPForum::Infrastructure::Storage->dbh_of( $self->schema );
    if ( !$dbh || !$dbh->can('selectall_arrayref') ) {
        return undef;
    }

    return _dbh_driver_name($dbh) eq 'Pg';
}

sub _dbh_driver_name ($dbh) {
    if ( $dbh->can('driver_name') ) {
        return $dbh->driver_name;
    }
    my $driver = $dbh->{Driver};

    return $driver ? $driver->{Name} || q{} : q{};
}

sub _search_rows ($search) {
    if ( $search->can('all') ) {
        return $search->all;
    }
    if ( $search->can('rows') ) {
        return @{ $search->rows };
    }

    return;
}

# One message from claim to outcome; answers the summary counters it adds
# to. A message whose claim another worker took is not dispatched; one
# handled after its claim was taken is not acknowledged, and one that failed
# then leaves its failure to the worker that owns it.
sub _handle ( $self, $message ) {
    if ( !$self->_renew_claim($message) ) {
        return $self->_lost( $message, 'before dispatching it; skipped' );
    }

    try {
        $self->transport->dispatch($message);
    }
    catch ($error) {
        return $self->_record_failure( $message, $error );
    };

    if ( !$self->_owned_write( $message, $self->_done_columns ) ) {
        return (
            'dispatched',
            $self->_lost(
                $message,
                'after dispatching it; another worker may deliver it again'
            )
        );
    }

    return qw(dispatched acknowledged);
}

# The lease starts again from now, so a message that waited in the batch is
# dispatched with a whole lease ahead of it. A message whose lease ran out
# while it waited is renewed all the same when no other worker claimed it.
# The resultset claim's rows have no other worker to lose them to.
sub _renew_claim ( $self, $message ) {
    if ( !_is_claimed_message($message) ) {
        return 1;
    }

    return $self->_owned_write(
        $message,
        {
            locked_until =>
              $self->clock->epoch_plus_iso8601( $self->retry->lock_seconds ),
        }
    );
}

# Writes the changes while the message is still this worker's and answers
# whether they landed. A claim on PostgreSQL gives ClaimedMessage rows,
# written with $OWNED_WHERE; the resultset claim, which runs on the schema
# doubles alone, gives DBIx::Class rows written as they are.
sub _owned_write ( $self, $message, $changes ) {
    if ( !_is_claimed_message($message) ) {
        $message->update($changes);
        return 1;
    }

    my @columns = sort keys %{$changes};
    my $landed  = _dbh_select_column(
        GPForum::Infrastructure::Storage->dbh_of( $self->schema ),
        _owned_update_sql(@columns),
        @{$changes}{@columns},
        $message->get_column('outbox_id'),
        $self->worker_id,
        $RUNNING_STATUS
    );
    if ( !@{ $landed || [] } ) {
        return 0;
    }
    $message->apply_columns($changes);

    return 1;
}

# The statement that writes these columns, built once: the dispatcher writes
# the same three sets of them -- the renewal, the acknowledgement, the
# failure -- message after message.
sub _owned_update_sql (@columns) {
    state %sql_for;

    return $sql_for{"@columns"} //= join q{ }, 'UPDATE', $OUTBOX_TABLE, 'SET',
      join( q{, }, map { $_ . ' = ?' } @columns ), $OWNED_WHERE;
}

# A message this worker no longer owns: counted, logged, and left to the
# worker that does.
sub _lost ( $self, $message, $moment ) {
    if ( $self->logger ) {
        $self->logger->warn(
            sprintf 'outbox message %s: %s lost its claim %s',
            $message->get_column('outbox_id') // q{?},
            $self->worker_id, $moment
        );
    }

    return 'lost';
}

sub _claimed_message_for_row {
    my ( $self, $row ) = @_;

    return GPForum::Service::Outbox::ClaimedMessage->new( row => $row );
}

sub _mark_running ( $self, $message ) {
    $message->update(
        {
            locked_at    => $self->clock->now_iso8601,
            locked_by    => $self->worker_id,
            locked_until =>
              $self->clock->epoch_plus_iso8601( $self->retry->lock_seconds ),
            status => $RUNNING_STATUS,
        }
    );

    return;
}

sub _done_columns ($self) {
    return {
        last_error       => undef,
        last_error_class => undef,
        locked_at        => undef,
        locked_by        => undef,
        locked_until     => undef,
        next_attempt_at  => $self->clock->now_iso8601,
        status           => $DONE_STATUS,
    };
}

# The status update and the dead-letter row are one fact about one failure,
# written in one transaction: written separately, a crash between them left
# a message cancelled -- terminal, never retried -- with no dead letter
# saying why. And both are this worker's to write only while it still owns
# the message: the update's affected row count used to be ignored, and a
# worker whose claim another had taken over, and acknowledged, still
# recorded a dead letter for a message that had been delivered.
sub _record_failure ( $self, $message, $exception ) {
    my $attempt_count = $self->retry->next_attempt($message);
    my $failure_type  = $self->failure_types->classify($exception);
    my $status        = $self->retry->status( $attempt_count, $failure_type );
    my $failure       = {
        attempt_count => $attempt_count,
        error_class   => ref $exception || $GENERIC_ERROR_CLASS,
        error_message => "$exception",
        failure_type  => $failure_type,
    };
    my $write = sub {
        if (
            !$self->_owned_write(
                $message, $self->_failed_columns( $status, $failure )
            )
          )
        {
            return 0;
        }
        if ( $self->retry->is_cancelled($status) ) {
            $self->dead_letter_recorder->create_dead_letter( $message,
                $failure );
        }
        return 1;
    };

    my $schema = $self->schema;
    my $recorded =
        $schema && $schema->can('txn_do')
      ? $schema->txn_do($write)
      : $write->();
    if ( !$recorded ) {
        return $self->_lost( $message,
            'after it failed; the failure is left to the worker that owns it' );
    }

    return $self->retry->is_cancelled($status) ? 'dead_lettered' : 'failed';
}

sub _failed_columns ( $self, $status, $failure ) {
    return {
        attempt_count    => $failure->{attempt_count},
        attempts         => $failure->{attempt_count},
        failure_type     => $failure->{failure_type},
        last_error       => $failure->{error_message},
        last_error_class => $failure->{error_class},
        locked_at        => undef,
        locked_by        => undef,
        locked_until     => undef,
        next_attempt_at  => $self->clock->epoch_plus_iso8601(
            $self->retry->backoff_seconds( $failure->{attempt_count} )
        ),
        status => $status,
    };
}

sub _is_claimed_message ($message) {
    return $message->can('is_direct_outbox_message')
      && $message->is_direct_outbox_message ? 1 : 0;
}

sub _dbh_select_column ( $dbh, $sql, @bind ) {
    if ( $dbh->can('select_column') ) {
        return $dbh->select_column( $sql, undef, @bind );
    }

    return $dbh->selectcol_arrayref( $sql, undef, @bind );
}

sub _dead_letter_recorder_args ($self) {
    my %args = (
        clock  => $self->clock,
        schema => $self->schema,
    );
    if ( $self->id_service ) {
        $args{id_service} = $self->id_service;
    }

    return %args;
}

1;

__END__

=head1 NAME

GPForum::Service::Outbox::Dispatcher - Claim, dispatch, retry, and dead-letter.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $summary = $dispatcher->dispatch_pending($limit);

=head1 DESCRIPTION

Claims ready outbox rows, dispatches them through a transport, and records
retry or dead-letter outcomes. Classification lives in
L<GPForum::Service::Outbox::FailureType>, attempt policy in
L<GPForum::Service::Outbox::Retry>, and PostgreSQL claim SQL in
L<GPForum::Service::Outbox::ClaimQuery>.

=head1 SUBROUTINES/METHODS

=head2 dispatch_pending

Claims a bounded batch and handles its messages in order, one at a time:
renews the message's claim for another C<lock_seconds>, dispatches it, and
writes its outcome at once -- C<done>, or the retry or cancellation and its
dead letter in one transaction. Each of those writes is an UPDATE on
C<locked_by> = this worker and C<status> = C<running>, so it lands only while
the message is still this worker's. A message whose claim another worker
took is not dispatched; one dispatched after that is not acknowledged; one
that failed after that records no failure and no dead letter. Each is logged
as a warning when a C<logger> is set.

Returns a hash reference of counts: C<selected>, C<dispatched> (the
transport accepted it), C<acknowledged>, C<failed> (scheduled for a retry),
C<dead_lettered> and C<lost> (a claim another worker took).

=head2 claim_ready_batch

Claims ready pending, failed, and stale running messages.

=head1 DIAGNOSTICS

Transport exceptions are classified and persisted on the outbox row. A lost
claim logs C<outbox message ID: WORKER lost its claim ...>, saying whether it
was lost before the dispatch, after it, or after a failure.

=head1 CONFIGURATION AND ENVIRONMENT

C<max_attempts> defaults to 5. PostgreSQL claim requires a C<Pg> DBI driver.
C<logger>, a L<Mojo::Log>, is optional: without one a lost claim is only
counted. C<worker_id> must tell this worker from every other one claiming
from the same table, since the claim is its to keep only while C<locked_by>
says so.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Mojo::Base>, L<GPForum::Infrastructure::Storage> and
the outbox helpers above.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Delivery is at-least-once. Handlers must be idempotent for replay after a
crash between dispatch and acknowledgement, and for a message whose own
dispatch outlasts its lease: another worker may claim and deliver it while
this one is still at it.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
