package GPForum::Service::Outbox::Dispatcher;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;
use Try::Tiny;

use GPForum::Service::Clock;
use GPForum::Service::Outbox::ClaimedMessage;
use GPForum::Service::Outbox::DeadLetterRecorder;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT        => 100;
const my $LOCK_SECONDS         => 60;
const my $PENDING_STATUS       => 'pending';
const my $FAILED_STATUS        => 'failed';
const my $RUNNING_STATUS       => 'running';
const my $DONE_STATUS          => 'done';
const my $CANCELLED_STATUS     => 'cancelled';
const my $GENERIC_ERROR_CLASS  => 'error';
const my $FIRST_FAILURE_OFFSET => 1;
const my $DEFAULT_MAX_ATTEMPTS => 5;
const my $OUTBOX_TABLE         => 'outbox_messages';
const my $CLAIM_READY_BATCH_SQL => join "\n",
  'WITH ready AS (',
  '    SELECT outbox_id, next_attempt_at, created_at',
  '      FROM outbox_messages',
  '     WHERE (',
  '               status IN (?, ?)',
  '           AND next_attempt_at <= ?::timestamptz',
  '           AND (locked_until IS NULL OR locked_until <= ?::timestamptz)',
  '           )',
  '        OR (',
  '               status = ?',
  '           AND locked_until IS NOT NULL',
  '           AND locked_until <= ?::timestamptz',
  '           )',
  '     ORDER BY next_attempt_at ASC, created_at ASC, outbox_id ASC',
  '     LIMIT ?',
  '     FOR UPDATE SKIP LOCKED',
  '),',
  'claimed AS (',
  '    UPDATE outbox_messages AS outbox',
  '       SET status = ?,',
  '           locked_at = ?::timestamptz,',
  '           locked_by = ?,',
  '           locked_until = ?::timestamptz',
  '      FROM ready',
  '     WHERE outbox.outbox_id = ready.outbox_id',
  ' RETURNING outbox.*',
  ')',
  'SELECT claimed.*',
  '  FROM claimed',
  '  JOIN ready ON ready.outbox_id = claimed.outbox_id',
' ORDER BY ready.next_attempt_at ASC, ready.created_at ASC, ready.outbox_id ASC';
const my @FAILURE_TYPE_RULES => (
    [ 'serialization', qr/Serial/imsx,           qr/serial/imsx ],
    [ 'authorization', qr/Authori[sz]ation/imsx, qr/forbidden|unauthor/imsx ],
    [ 'transport',     qr/Transport|Notify|Pg/imsx, qr/transport|notify/imsx ],
    [ 'permanent',     qr/Permanent/imsx,           qr/permanent/imsx ],
);

has schema               => undef;
has transport            => undef;
has clock                => sub { return GPForum::Service::Clock->new; };
has worker_id            => 'worker';
has max_attempts         => $DEFAULT_MAX_ATTEMPTS;
has dead_letter_recorder => sub {
    my ($self) = @_;

    return GPForum::Service::Outbox::DeadLetterRecorder->new(
        schema => $self->schema,
        clock  => $self->clock,
    );
};

sub dispatch_pending {
    my ( $self, $limit ) = @_;

    my @messages = $self->claim_ready_batch( $limit || $DEFAULT_LIMIT );
    my @done_messages;
    my %summary = (
        selected      => scalar @messages,
        dispatched    => 0,
        failed        => 0,
        dead_lettered => 0,
        acknowledged  => 0,
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

sub claim_ready_batch {
    my ( $self, $limit ) = @_;

    return $self->_claim_ready_batch_postgresql($limit)
      if $self->_supports_postgresql_claim;

    return $self->_claim_ready_batch_resultset($limit);
}

sub _count_outcome {
    my ( $summary, $outcome ) = @_;

    my %counter_for = (
        $DONE_STATUS      => 'dispatched',
        $CANCELLED_STATUS => 'dead_lettered',
        $FAILED_STATUS    => 'failed',
    );
    my $counter = $counter_for{$outcome} || 'failed';

    $summary->{$counter} += 1;

    return;
}

sub _claim_ready_batch_postgresql {
    my ( $self, $limit ) = @_;

    my $messages = $self->schema->txn_do(
        sub {
            my $now          = $self->clock->now_iso8601;
            my $locked_until = $self->clock->epoch_plus_iso8601($LOCK_SECONDS);
            my @rows =
              $self->_claim_ready_rows_postgresql( $limit, $now,
                $locked_until );

            return [ map { $self->_claimed_message_for_row($_) } @rows ];
        }
    );

    return @{$messages};
}

sub _claim_ready_rows_postgresql {
    my ( $self, $limit, $now, $locked_until ) = @_;

    my $dbh  = _schema_dbh($self);
    my $rows = $dbh->selectall_arrayref(
        $CLAIM_READY_BATCH_SQL, { Slice => {} }, $PENDING_STATUS,
        $FAILED_STATUS,  $now, $now,
        $RUNNING_STATUS, $now, $limit,
        $RUNNING_STATUS, $now, $self->worker_id,
        $locked_until,
    );

    return @{$rows};
}

sub _claim_ready_batch_resultset {
    my ( $self, $limit ) = @_;

    my $now      = $self->clock->now_iso8601;
    my @messages = _search_rows(
        $self->schema->resultset('OutboxMessage')->search(
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

sub _supports_postgresql_claim {
    my ($self) = @_;

    return if !$self->schema->can('txn_do');

    my $dbh = _schema_dbh($self);
    return if !$dbh;
    return if !$dbh->can('selectall_arrayref');

    return _dbh_driver_name($dbh) eq 'Pg';
}

sub _schema_dbh {
    my ($self) = @_;

    my $storage = try { return $self->schema->storage; }
    catch { return; };

    return if !$storage;

    my $dbh = try { return $storage->dbh; }
    catch { return; };

    return $dbh;
}

sub _dbh_driver_name {
    my ($dbh) = @_;

    return $dbh->driver_name if $dbh->can('driver_name');

    my $driver = $dbh->{Driver};
    return q{} if !$driver;

    return $driver->{Name} || q{};
}

sub _search_rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _dispatch_one {
    my ( $self, $message ) = @_;

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

sub _mark_running {
    my ( $self, $message ) = @_;

    $message->update(
        {
            status       => $RUNNING_STATUS,
            locked_at    => $self->clock->now_iso8601,
            locked_by    => $self->worker_id,
            locked_until => $self->clock->epoch_plus_iso8601($LOCK_SECONDS),
        }
    );

    return;
}

sub _mark_done {
    my ( $self, $message ) = @_;

    $message->update(
        {
            status           => $DONE_STATUS,
            locked_at        => undef,
            locked_by        => undef,
            locked_until     => undef,
            last_error       => undef,
            last_error_class => undef,
            next_attempt_at  => $self->clock->now_iso8601,
        }
    );

    return;
}

sub _mark_done_batch {
    my ( $self, @messages ) = @_;

    return 0 if !@messages;

    if ( _all_direct_messages(@messages) && $self->_supports_postgresql_claim )
    {
        $self->_mark_done_batch_postgresql(@messages);
        return scalar @messages;
    }

    for my $message (@messages) {
        $self->_mark_done($message);
    }

    return scalar @messages;
}

sub _mark_done_batch_postgresql {
    my ( $self, @messages ) = @_;

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

    _dbh_do( _schema_dbh($self), $sql, $DONE_STATUS, $now, @ids,
        $self->worker_id, $RUNNING_STATUS );

    for my $message (@messages) {
        $message->apply_columns(
            {
                status           => $DONE_STATUS,
                locked_at        => undef,
                locked_by        => undef,
                locked_until     => undef,
                last_error       => undef,
                last_error_class => undef,
                next_attempt_at  => $now,
            }
        );
    }

    return;
}

sub _mark_failed {
    my ( $self, $message, $exception ) = @_;

    my $attempt_count = _next_attempt_count($message);

    my $failure = {
        attempt_count => $attempt_count,
        error_class   => ref $exception || $GENERIC_ERROR_CLASS,
        error_message => "$exception",
        failure_type  => _failure_type($exception),
    };
    my $status =
        $attempt_count >= $self->max_attempts
      ? $CANCELLED_STATUS
      : $FAILED_STATUS;

    $message->update(
        {
            status           => $status,
            attempts         => $attempt_count,
            attempt_count    => $attempt_count,
            locked_at        => undef,
            locked_by        => undef,
            locked_until     => undef,
            last_error       => $failure->{error_message},
            last_error_class => $failure->{error_class},
            failure_type     => $failure->{failure_type},
            next_attempt_at  => $self->clock->epoch_plus_iso8601(
                $attempt_count * $LOCK_SECONDS
            ),
        }
    );

    if ( $status eq $CANCELLED_STATUS ) {
        $self->dead_letter_recorder->create_dead_letter( $message, $failure );
    }

    return $status;
}

sub _update_outbox_message_postgresql {
    my ( $self, $message, $changes ) = @_;

    my @columns = sort keys %{$changes};
    return if !@columns;

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

sub _all_direct_messages {
    my (@messages) = @_;

    for my $message (@messages) {
        return if !$message->can('is_direct_outbox_message');
        return if !$message->is_direct_outbox_message;
    }

    return 1;
}

sub _dbh_do {
    my ( $dbh, $sql, @bind ) = @_;

    return $dbh->execute_statement( $sql, undef, @bind )
      if $dbh->can('execute_statement');

    return $dbh->do( $sql, undef, @bind );
}

sub _next_attempt_count {
    my ($message) = @_;

    my $current = $message->get_column('attempt_count') || 0;

    return $current + $FIRST_FAILURE_OFFSET;
}

sub _failure_type {
    my ($exception) = @_;

    my $declared = _declared_failure_type($exception);
    return $declared if defined $declared;

    my $class = ref $exception || q{};
    my $text  = "$exception";

    for my $rule (@FAILURE_TYPE_RULES) {
        return $rule->[0] if _matches_failure_rule( $class, $text, $rule );
    }

    return 'transient';
}

sub _declared_failure_type {
    my ($exception) = @_;

    return if !ref $exception;
    return if !$exception->can('failure_type');

    return $exception->failure_type;
}

sub _matches_failure_rule {
    my ( $class, $text, $rule ) = @_;

    return $class =~ $rule->[1] || $text =~ $rule->[2] ? 1 : 0;
}

1;
