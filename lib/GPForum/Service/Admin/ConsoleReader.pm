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

# The only address a console action may mail on an administrator's behalf:
# their own (Admin::Diagnostics' test message). Undef for no such account.
sub email_of ( $self, $user_id ) {
    my $search = $self->schema->resultset('User')->search_rs(
        {
            deleted_at => undef,
            id         => $user_id,
        },
        { columns => ['email_normalized'] }
    );

    return _column( $search->single, 'email_normalized' );
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

__END__

=head1 NAME

GPForum::Service::Admin::ConsoleReader - Read-only queries behind the administration console.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $reader = GPForum::Service::Admin::ConsoleReader->new(
        metrics_snapshot => $metrics_snapshot,
        readiness        => $readiness,
        schema           => $schema,
    );
    my $summary = $reader->dashboard_summary( { limit => 10 } );
    my $users   = $reader->list_users( { status => 'active', limit => 50 } );
    my $jobs    = $reader->async_jobs( { limit => 25 } );
    my $email   = $reader->email_of($admin_user_id);

=head1 DESCRIPTION

Everything the console's dashboard and lists read: members, open reports,
outbox messages, dead letters and the health of the running system. It
writes nothing.

Every list is bounded by C<limit> (default 25) and selects only the
columns it returns, each row as a plain hash reference. The queue depth and
the dead-letter total are counted, not measured from those lists: the
dashboard used to count a list already cut to its limit, so both totals
stopped at the limit whatever the real number was.

A dead letter carries its replay status from the same statement (see
L<GPForum::Service::Outbox::DeadLetterReplay/replay_status_sql>), so the
page does not spend a query per row on it.

The health block never fails the page: readiness, metrics and query budget
each fall back to a placeholder when their collector dies or is not set.
The attributes are C<schema>, which every query needs, C<readiness> and
C<metrics_snapshot>, both optional, and C<query_budget>, which defaults to
a L<GPForum::Service::Operations::QueryBudget> over the schema.

=head1 SUBROUTINES/METHODS

=head2 dashboard_summary

Takes a hash reference (or undef) with an optional C<limit>. Returns a hash
reference with C<async> (as C<async_jobs>), C<health> (as
C<operations_status>), C<< moderation => { reports => [...] } >> (the open
reports) and C<users> (as C<list_users>), each list bounded by the limit.

=head2 list_users

Takes a hash reference (or undef) with optional C<status> and C<limit>.
Returns an array reference of the members not deleted, newest first and
then by username, each a hash reference of C<id>, C<username>,
C<display_name>, C<email_normalized>, C<status>, C<trust_level>,
C<email_verified_at>, C<created_at>, C<updated_at> and C<deleted_at>.

=head2 email_of

Takes a user id. Returns that member's normalized address, or undef when
there is no such member or the account is deleted. It is the only address
a console action may mail on an administrator's behalf: their own, for
L<GPForum::Service::Admin::Diagnostics>' test message.

=head2 list_reports

Takes a hash reference (or undef) with optional C<status> (default
C<open>) and C<limit>. Returns an array reference of the reports in that
status, oldest first, each a hash reference of C<report_id>,
C<reporter_user_id>, C<target_type>, C<target_id>, C<reason>, C<details>,
C<status>, C<assigned_moderator_user_id>, C<created_at>, C<resolved_at>
and C<resolution>.

=head2 async_jobs

Takes a hash reference (or undef) of the options C<list_outbox> and
C<list_dead_letters> take. Returns a hash reference with C<dead_letters>
and C<outbox_messages> (the two lists) and C<dead_letter_total> and
C<outbox_message_total> (the full counts).

=head2 count_dead_letters

Returns the number of rows in C<dead_letters>, or 0 when the count fails.

=head2 count_outbox

Returns the number of rows in C<outbox_messages>, whatever their status, or
0 when the count fails.

=head2 list_outbox

Takes a hash reference (or undef) with optional C<status> and C<limit>.
Returns an array reference of outbox messages, newest first, each a hash
reference of its queue, job, lock, attempt and error columns.

=head2 list_dead_letters

Takes a hash reference (or undef) with an optional C<limit>. Returns an
array reference of dead letters, the most recently failed first, each a
hash reference of its source, error and retry columns plus
C<replay_status>: the replay message's status while it is kept,
C<replayed> once only the audit log remembers it, undef when it was never
replayed.

=head2 operations_status

Returns a hash reference with C<readiness> (the readiness check, or
C<< { status => 'unknown', checks => [] } >>), C<metrics> (the metrics
snapshot, or an empty hash), C<query_budgets> (the query budget snapshot,
or C<< { endpoints => {} } >>), C<query_budget_drift> (the drift report, or
C<< { status => 'unknown' } >>) and C<benchmark>, which names the
benchmark commands and reports C<manual>: no benchmark baseline is
persisted.

=head1 DIAGNOSTICS

The lists and C<email_of> die when the database does. The counts return 0
instead, and C<operations_status> returns its placeholders, so a failing
collector does not take the dashboard with it.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, L<GPForum::Infrastructure::Row>,
L<GPForum::Service::Outbox::DeadLetterReplay>,
L<GPForum::Service::Operations::QueryBudget>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A count that fails reads as 0, the same as an empty queue.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
