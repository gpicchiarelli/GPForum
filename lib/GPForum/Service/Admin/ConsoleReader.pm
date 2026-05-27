package GPForum::Service::Admin::ConsoleReader;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

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
  dead_letter_id source_table source_id error_class error_message retry_count
  first_failed_at last_failed_at
);

has metrics_snapshot => undef;
has query_budget     => sub {
    my ($self) = @_;

    return GPForum::Service::Operations::QueryBudget->new(
        schema => $self->schema );
};
has readiness => undef;
has schema    => undef;

sub dashboard_summary {
    my ( $self, $options ) = @_;

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

sub list_users {
    my ( $self, $options ) = @_;

    $options ||= {};

    my $query = { deleted_at => undef };
    if ( _has_text( $options->{status} ) ) {
        $query->{status} = $options->{status};
    }

    my $search = $self->schema->resultset('User')->search(
        $query,
        {
            columns  => \@USER_COLUMNS,
            order_by => [ { -desc => 'created_at' }, { -asc => 'username' } ],
            rows     => _limit($options),
        }
    );

    return [ map { _row_hash( $_, @USER_COLUMNS ) } _rows($search) ];
}

sub list_reports {
    my ( $self, $options ) = @_;

    $options ||= {};

    my $search = $self->schema->resultset('Report')->search(
        { status => $options->{status} || $STATUS_OPEN },
        {
            columns  => \@REPORT_COLUMNS,
            order_by => [ { -asc => 'created_at' }, { -asc => 'report_id' } ],
            rows     => _limit($options),
        }
    );

    return [ map { _row_hash( $_, @REPORT_COLUMNS ) } _rows($search) ];
}

sub async_jobs {
    my ( $self, $options ) = @_;

    $options ||= {};

    return {
        dead_letters    => $self->list_dead_letters($options),
        outbox_messages => $self->list_outbox($options),
    };
}

sub list_outbox {
    my ( $self, $options ) = @_;

    $options ||= {};

    my $query = {};
    if ( _has_text( $options->{status} ) ) {
        $query->{status} = $options->{status};
    }

    my $search = $self->schema->resultset('OutboxMessage')->search(
        $query,
        {
            columns  => \@OUTBOX_COLUMNS,
            order_by => [ { -desc => 'created_at' }, { -desc => 'outbox_id' } ],
            rows     => _limit($options),
        }
    );

    return [ map { _row_hash( $_, @OUTBOX_COLUMNS ) } _rows($search) ];
}

sub list_dead_letters {
    my ( $self, $options ) = @_;

    $options ||= {};

    my $search = $self->schema->resultset('DeadLetter')->search(
        {},
        {
            columns  => \@DEAD_LETTER_COLUMNS,
            order_by =>
              [ { -desc => 'last_failed_at' }, { -desc => 'dead_letter_id' } ],
            rows => _limit($options),
        }
    );

    return [ map { _row_hash( $_, @DEAD_LETTER_COLUMNS ) } _rows($search) ];
}

sub operations_status {
    my ($self) = @_;

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

sub _safe_call {
    my ( $callback, $fallback ) = @_;

    my $result = eval { return $callback->(); };
    return $result if !$EVAL_ERROR && defined $result;

    return $fallback;
}

sub _limit {
    my ($options) = @_;

    return $options->{limit} || $DEFAULT_LIMIT;
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _row_hash {
    my ( $row, @columns ) = @_;

    return { map { $_ => _column( $row, $_ ) } @columns };
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->{$column}           if ref $row eq 'HASH';
    return $row->get_column($column) if $row && $row->can('get_column');

    return;
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value;
}

1;
