# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Outbox::Dispatcher;

use strict;
use warnings;

use Const::Fast;
use GPForum::Service::Clock;
use GPForum::Service::Outbox::ClaimedMessage;
use GPForum::Service::Outbox::ClaimQuery;
use GPForum::Service::Outbox::DeadLetterRecorder;
use GPForum::Service::Outbox::FailureType;
use GPForum::Service::Outbox::Retry;
use Mojo::Base -base, -signatures;
use Try::Tiny;

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

has schema        => undef;
has transport     => undef;
has clock         => sub { return GPForum::Service::Clock->new; };
has worker_id     => 'worker';
has max_attempts  => $DEFAULT_MAX_ATTEMPTS;
has id_service    => undef;
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

sub dispatch_pending ( $self, $limit ) {
    my @messages = $self->claim_ready_batch( $limit || $DEFAULT_LIMIT );
    my @done_messages;
    my %summary = (
        acknowledged  => 0,
        dead_lettered => 0,
        dispatched    => 0,
        failed        => 0,
        selected      => scalar @messages,
    );

    for my $message (@messages) {
        my $outcome = $self->_dispatch_one($message);
        if ( $outcome eq $DONE_STATUS ) {
            push @done_messages, $message;
        }
        _count_outcome( \%summary, $outcome );
    }

    $summary{acknowledged} = $self->_mark_done_batch(@done_messages);

    return \%summary;
}

sub claim_ready_batch ( $self, $limit ) {
    if ( $self->_supports_postgresql_claim ) {
        return $self->_claim_ready_batch_postgresql($limit);
    }

    return $self->_claim_ready_batch_resultset($limit);
}

sub _count_outcome ( $summary, $outcome ) {
    my %counter_for = (
        $CANCELLED_STATUS => 'dead_lettered',
        $DONE_STATUS      => 'dispatched',
        $FAILED_STATUS    => 'failed',
    );
    my $counter = $counter_for{$outcome} || 'failed';
    $summary->{$counter} += 1;

    return;
}

sub _claim_ready_batch_postgresql ( $self, $limit ) {
    my $messages = $self->schema->txn_do(
        sub {
            return $self->_claimed_postgresql_messages($limit);
        }
    );

    return @{$messages};
}

sub _claimed_postgresql_messages ( $self, $limit ) {
    my $now = $self->clock->now_iso8601;
    my $locked_until =
      $self->clock->epoch_plus_iso8601( $self->retry->lock_seconds );
    my @rows =
      $self->_claim_ready_rows_postgresql( $limit, $now, $locked_until );

    return [ map { $self->_claimed_message_for_row($_) } @rows ];
}

sub _claim_ready_rows_postgresql ( $self, $limit, $now, $locked_until ) {
    my $dbh  = _schema_dbh($self);
    my $rows = $dbh->selectall_arrayref(
        $self->claim_query->sql,
        { Slice => {} },
        @{
            $self->claim_query->bind_values(
                {
                    limit        => $limit,
                    locked_until => $locked_until,
                    now          => $now,
                    worker_id    => $self->worker_id,
                }
            )
        },
    );

    return @{$rows};
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
    my $undefined;

    if ( !$self->schema->can('txn_do') ) {
        return $undefined;
    }

    my $dbh = _schema_dbh($self);
    if ( !$dbh || !$dbh->can('selectall_arrayref') ) {
        return $undefined;
    }

    return _dbh_driver_name($dbh) eq 'Pg';
}

sub _schema_dbh ($self) {
    my $storage = try { return $self->schema->storage; }
    catch { return; };
    if ( !$storage ) {
        my $undefined;
        return $undefined;
    }

    my $dbh = try { return $storage->dbh; }
    catch { return; };

    return $dbh;
}

sub _dbh_driver_name ($dbh) {
    if ( $dbh->can('driver_name') ) {
        return $dbh->driver_name;
    }

    return _driver_from_handle($dbh);
}

sub _driver_from_handle ($dbh) {
    my $driver = $dbh->{Driver};
    if ( !$driver ) {
        return q{};
    }

    return $driver->{Name} || q{};
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

sub _dispatch_one ( $self, $message ) {
    my $outcome = try {
        $self->transport->dispatch($message);
        return $DONE_STATUS;
    }
    catch {
        return $self->_mark_failed( $message, $_ );
    };

    return $outcome;
}

sub _claimed_message_for_row {
    my ( $self, $row ) = @_;

    return GPForum::Service::Outbox::ClaimedMessage->new(
        row            => $row,
        update_handler => sub {
            my ( $message, $changes ) = @_;
            $self->_update_outbox_message_postgresql( $message, $changes );
        },
    );
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

sub _mark_done ( $self, $message ) {
    $message->update( $self->_done_columns( $self->clock->now_iso8601 ) );

    return;
}

sub _done_columns ( $, $now ) {
    return {
        last_error       => undef,
        last_error_class => undef,
        locked_at        => undef,
        locked_by        => undef,
        locked_until     => undef,
        next_attempt_at  => $now,
        status           => $DONE_STATUS,
    };
}

sub _mark_done_batch ( $self, @messages ) {
    if ( !@messages ) {
        return 0;
    }
    if ( _all_direct_messages(@messages) && $self->_supports_postgresql_claim )
    {
        return $self->_mark_done_batch_postgresql(@messages);
    }

    return $self->_mark_done_each(@messages);
}

sub _mark_done_each ( $self, @messages ) {
    for my $message (@messages) {
        $self->_mark_done($message);
    }

    return scalar @messages;
}

sub _mark_done_batch_postgresql ( $self, @messages ) {
    my @ids          = map { $_->get_column('outbox_id') } @messages;
    my $placeholders = join q{,}, map { q{?} } @ids;
    my $now          = $self->clock->now_iso8601;
    my $sql          = join q{ },
      'UPDATE', $OUTBOX_TABLE,
      'SET status = ?, locked_at = NULL, locked_by = NULL,',
      'locked_until = NULL, last_error = NULL, last_error_class = NULL,',
      'next_attempt_at = ?',
      'WHERE outbox_id IN (' . $placeholders . ')',
      'AND locked_by = ? AND status = ?';

    # RETURNING, because the WHERE clause can match fewer rows than were
    # asked for: a message whose lease expired and was re-claimed by another
    # worker no longer satisfies locked_by/status. The affected count used to
    # be discarded, every in-memory message was stamped done regardless, and
    # dispatch_pending reported all of them as acknowledged. Only the rows the
    # database actually acknowledged are counted now.
    my $acknowledged =
      _dbh_select_column( _schema_dbh($self), $sql . ' RETURNING outbox_id',
        $DONE_STATUS, $now, @ids, $self->worker_id, $RUNNING_STATUS );
    my %confirmed = map { $_ => 1 } @{ $acknowledged || [] };
    my @applied =
      grep { $confirmed{ $_->get_column('outbox_id') } } @messages;
    $self->_apply_done_columns( \@applied, $now );

    return scalar @applied;
}

sub _apply_done_columns ( $self, $messages, $now ) {
    my $changes = $self->_done_columns($now);
    for my $message ( @{$messages} ) {
        $message->apply_columns($changes);
    }

    return;
}

sub _mark_failed ( $self, $message, $exception ) {
    my $attempt_count = $self->retry->next_attempt($message);
    my $failure_type  = $self->failure_types->classify($exception);
    my $status        = $self->retry->status( $attempt_count, $failure_type );
    my $failure       = {
        attempt_count => $attempt_count,
        error_class   => ref $exception || $GENERIC_ERROR_CLASS,
        error_message => "$exception",
        failure_type  => $failure_type,
    };
    $self->_record_failure( $message, $status, $failure );

    return $status;
}

# The status update and the dead-letter row are one fact about one failure.
# Written separately, a crash between them left a message marked cancelled --
# terminal, never retried -- with no dead letter recording why, so the failure
# disappeared from the operational record entirely.
sub _record_failure ( $self, $message, $status, $failure ) {
    my $write = sub {
        $message->update( $self->_failed_columns( $status, $failure ) );
        $self->_record_dead_letter( $message, $status, $failure );
        return 1;
    };

    my $schema = $self->schema;
    return $write->() if !$schema || !$schema->can('txn_do');

    return $schema->txn_do($write);
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

sub _record_dead_letter ( $self, $message, $status, $failure ) {
    if ( $self->retry->is_cancelled($status) ) {
        $self->dead_letter_recorder->create_dead_letter( $message, $failure );
    }

    return;
}

sub _update_outbox_message_postgresql ( $self, $message, $changes ) {
    my @columns = sort keys %{$changes};
    if ( !@columns ) {
        return;
    }

    my @assignments = map { $_ . ' = ?' } @columns;
    my $sql         = join q{ },
      'UPDATE', $OUTBOX_TABLE,
      'SET',    join( q{, }, @assignments ),
      'WHERE outbox_id = ? AND locked_by = ?';
    my @values = map { $changes->{$_} } @columns;

    _dbh_do( _schema_dbh($self), $sql, @values,
        $message->get_column('outbox_id'),
        $self->worker_id );

    return;
}

sub _all_direct_messages (@messages) {
    for my $message (@messages) {
        if ( !$message->can('is_direct_outbox_message') ) {
            return;
        }
        if ( !$message->is_direct_outbox_message ) {
            return;
        }
    }

    return 1;
}

sub _dbh_select_column ( $dbh, $sql, @bind ) {
    if ( $dbh->can('select_column') ) {
        return $dbh->select_column( $sql, undef, @bind );
    }

    return $dbh->selectcol_arrayref( $sql, undef, @bind );
}

sub _dbh_do ( $dbh, $sql, @bind ) {
    if ( $dbh->can('execute_statement') ) {
        return $dbh->execute_statement( $sql, undef, @bind );
    }

    return $dbh->do( $sql, undef, @bind );
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

Claims a bounded batch, dispatches each message, and acknowledges successes.

=head2 claim_ready_batch

Claims ready pending, failed, and stale running messages.

=head1 DIAGNOSTICS

Transport exceptions are classified and persisted on the outbox row.

=head1 CONFIGURATION AND ENVIRONMENT

C<max_attempts> defaults to 5. PostgreSQL claim requires a C<Pg> DBI driver.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<Mojo::Base>, L<Try::Tiny>, and the outbox helpers
above.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Delivery is at-least-once. Handlers must be idempotent for replay after a
crash between dispatch and acknowledgement.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
