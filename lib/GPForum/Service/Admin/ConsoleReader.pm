# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::ConsoleReader;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Service::Outbox::DeadLetterReplay;
use GPForum::Service::Operations::QueryBudget;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT => 25;
const my $STATUS_OPEN   => 'open';

const my @USER_COLUMNS => qw(
  id username display_name email_normalized status trust_level
  email_verified_at created_at updated_at deleted_at
);
const my @REPORT_COLUMNS => qw(
  report_id reporter_user_id target_type target_id reason details status
  assigned_moderator_user_id created_at resolved_at resolution
);
const my @OUTBOX_COLUMNS => qw(
  outbox_id event_id queue job_type idempotency_key available_at created_at
  locked_at attempts status last_error next_attempt_at locked_by locked_until
  attempt_count last_error_class
);
const my @DEAD_LETTER_COLUMNS => qw(
  dead_letter_id source_table source_id error_class error_message failure_type
  retry_count first_failed_at last_failed_at
);

has metrics_snapshot => undef;
has query_budget     => sub {
    my ($self) = @_;

    return GPForum::Service::Operations::QueryBudget->new(
        schema => $self->schema );
};
has readiness => undef;
has schema    => undef;

sub dashboard_summary ( $self, $options ) {
    $options ||= {};
    my $limit = _limit($options);

    return {
        async      => $self->async_jobs( { limit => $limit } ),
        health     => $self->operations_status,
        moderation => {
            reports => $self->list_reports(
                {
                    limit  => $limit,
                    status => $STATUS_OPEN,
                }
            ),
        },
        users => $self->list_users( { limit => $limit } ),
    };
}

sub list_users ( $self, $options ) {
    $options ||= {};

    my $query = { deleted_at => undef };
    if ( _has_text( $options->{status} ) ) {
        $query->{status} = $options->{status};
    }

    my $search = $self->schema->resultset('User')->search_rs(
        $query,
        {
            columns  => \@USER_COLUMNS,
            order_by => [ { -desc => 'created_at' }, { -asc => 'username' } ],
            rows     => _limit($options),
        }
    );

    return [ map { _row_hash( $_, @USER_COLUMNS ) } _rows($search) ];
}

sub list_reports ( $self, $options ) {
    $options ||= {};

    my $search = $self->schema->resultset('Report')->search_rs(
        { status => $options->{status} || $STATUS_OPEN },
        {
            columns  => \@REPORT_COLUMNS,
            order_by => [ { -asc => 'created_at' }, { -asc => 'report_id' } ],
            rows     => _limit($options),
        }
    );

    return [ map { _row_hash( $_, @REPORT_COLUMNS ) } _rows($search) ];
}

sub async_jobs ( $self, $options ) {
    $options ||= {};

    return {
        dead_letters    => $self->list_dead_letters($options),
        outbox_messages => $self->list_outbox($options),

        # Counted, not measured from the lists above. The dashboard used to
        # print `scalar @{ ... }` over a list the reader had already truncated
        # to the dashboard limit, so the queue depth and the dead-letter total
        # both stopped at 10 -- the one number an operator reads to judge
        # whether the system is healthy said the same thing for eleven rows
        # and for fifty thousand.
        dead_letter_total    => $self->count_dead_letters,
        outbox_message_total => $self->count_outbox,
    };
}

sub count_dead_letters ($self) {
    return $self->_count('DeadLetter');
}

sub count_outbox ($self) {
    return $self->_count('OutboxMessage');
}

sub _count ( $self, $source ) {
    my $count = eval { return $self->schema->resultset($source)->count; };
    return 0 if !defined $count;

    return $count;
}

sub list_outbox ( $self, $options ) {
    $options ||= {};

    my $query = {};
    if ( _has_text( $options->{status} ) ) {
        $query->{status} = $options->{status};
    }

    my $search = $self->schema->resultset('OutboxMessage')->search_rs(
        $query,
        {
            columns  => \@OUTBOX_COLUMNS,
            order_by => [ { -desc => 'created_at' }, { -desc => 'outbox_id' } ],
            rows     => _limit($options),
        }
    );

    return [ map { _row_hash( $_, @OUTBOX_COLUMNS ) } _rows($search) ];
}

sub list_dead_letters ( $self, $options ) {
    $options ||= {};

    my $search = $self->schema->resultset('DeadLetter')->search_rs(
        {},
        {
            columns   => \@DEAD_LETTER_COLUMNS,
            '+select' => [ _replay_status_sql() ],
            '+as'     => ['replay_status'],
            order_by  =>
              [ { -desc => 'last_failed_at' }, { -desc => 'dead_letter_id' } ],
            rows => _limit($options),
        }
    );

    return [ map { _row_hash( $_, @DEAD_LETTER_COLUMNS, 'replay_status' ) }
          _rows($search) ];
}

# Whether each dead letter was replayed, and how its replay is doing, in the
# same statement: index lookups per row rather than a second query the page's
# query budget has no room for.
sub _replay_status_sql {
    return GPForum::Service::Outbox::DeadLetterReplay->replay_status_sql(
        'me.dead_letter_id');
}

sub operations_status ($self) {
    my $readiness = _safe_call(
        sub { return $self->readiness->check; },
        { status => 'unknown', checks => [] }
    );
    my $metrics =
      _safe_call( sub { return $self->metrics_snapshot->collect; }, {} );
    my $query_budgets =
      _safe_call( sub { return $self->query_budget->snapshot; },
        { endpoints => {} } );
    my $query_budget_drift =
      _safe_call(
        sub { return $self->query_budget->drift_report( $self->schema ); },
        { status => 'unknown' } );

    return {
        benchmark => {
            configured_command => 'script/benchmark-http --configured --check',
            fixture_command    => 'script/benchmark-http --fixture --check',
            persisted_baseline => 0,
            status             => 'manual',
        },
        metrics            => $metrics,
        query_budget_drift => $query_budget_drift,
        query_budgets      => $query_budgets,
        readiness          => $readiness,
    };
}

sub _safe_call ( $callback, $fallback ) {
    my $result = eval { return $callback->(); };
    return $result if !$EVAL_ERROR && defined $result;

    return $fallback;
}

sub _limit ($options) {
    return $options->{limit} || $DEFAULT_LIMIT;
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _row_hash ( $row, @columns ) {
    return { map { $_ => _column( $row, $_ ) } @columns };
}

sub _column ( $row, $column ) {
    return GPForum::Infrastructure::Row->column( $row, $column );
}

sub _has_text ($value) {
    return defined $value && length $value;
}

1;
