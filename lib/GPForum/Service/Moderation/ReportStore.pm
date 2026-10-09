# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Moderation::ReportStore;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::Storage;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Moderation::Event;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $DEFAULT_QUEUE_LIMIT => 50;
const my $ID_CONSTRAINT       => 'reports_pkey';
const my $OPEN_CONSTRAINT     => 'idx_reports_reporter_target_open_unique';
const my $STATUS_OPEN         => 'open';
const my $STATUS_RESOLVED     => 'resolved';
const my $STATUS_TRIAGED      => 'triaged';
const my $REPORT_LOCK_SQL =>
  'SELECT report_id FROM reports WHERE report_id = ? FOR UPDATE';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub {
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has recorder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
__PACKAGE__->requires(qw(schema));
has events => sub { return GPForum::Service::Moderation::Event->new; };

# The member's open report on the same target is reused, whether it was
# there before or a concurrent report won the open key; a minted id already
# stored with no such report is minted once more.
sub create_report ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            my $duplicate = $self->_open_duplicate_report($input);
            if ($duplicate) {
                return $self->_finish_leftover_report( $duplicate, $input );
            }

            my $insert = sub { return $self->_insert_report($input); };
            my ( $created, $error ) =
              GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
                $insert );
            if ($created) {
                return $created;
            }

            my $conflict = GPForum::X::Conflict->caught($error);
            my $id_taken = $conflict && $conflict->on($ID_CONSTRAINT);
            if ( $id_taken
                || ( $conflict && $conflict->on($OPEN_CONSTRAINT) ) )
            {
                $duplicate = $self->_open_duplicate_report($input);
                if ($duplicate) {
                    return $self->_finish_leftover_report( $duplicate, $input );
                }
            }
            if ( !$id_taken ) {
                GPForum::Infrastructure::UniqueConflict->rethrow($error);
            }

            ( $created, $error ) =
              GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
                $insert );
            if ($created) {
                return $created;
            }
            GPForum::Infrastructure::UniqueConflict->rethrow($error);
        }
    );
}

sub _open_duplicate_report ( $self, $input ) {
    return $self->schema->resultset('Report')->search_rs(
        {
            reporter_user_id => $input->{reporter_user_id},
            target_type      => $input->{target_type},
            target_id        => $input->{target_id},
            status           => { -in => [ $STATUS_OPEN, $STATUS_TRIAGED ] },
        },
        {
            order_by => { -desc => 'created_at' },
            rows     => 1,
        }
    )->single;
}

sub _insert_report ( $self, $input ) {
    my $created_at = $self->clock->now_iso8601;
    my $report     = {
        report_id                  => $self->id_service->uuid,
        reporter_user_id           => $input->{reporter_user_id},
        target_type                => $input->{target_type},
        target_id                  => $input->{target_id},
        reason                     => $input->{reason},
        details                    => $input->{details} || q{},
        status                     => $STATUS_OPEN,
        assigned_moderator_user_id => undef,
        created_at                 => $created_at,
        resolved_at                => undef,
        resolution                 => undef,
    };

    $self->schema->resultset('Report')->create($report);
    $self->_record_event_and_audit($report);

    return $report;
}

# A report whose event an earlier attempt left out gets it now; a report
# already recorded is a duplicate, and the repeat is audited as one.
sub _finish_leftover_report ( $self, $existing, $input ) {
    my $event_key = join q{:}, 'report.created',
      _column( $existing, 'report_id' );
    if ( !$self->recorder->event_recorded($event_key) ) {
        $self->_record_event_and_audit($existing);
        return $existing;
    }

    $self->recorder->record_audit(
        %{
            $self->events->report_duplicate_audit(
                {
                    created_at       => $self->clock->now_iso8601,
                    duplicate        => $existing,
                    reason           => $input->{reason},
                    reporter_user_id => $input->{reporter_user_id},
                    target_id        => $input->{target_id},
                    target_type      => $input->{target_type},
                }
            )
        }
    );

    return $existing;
}

sub assign_report ( $self, $report_id, $moderator_user_id ) {
    return $self->schema->txn_do(
        sub {
            $self->_lock_report($report_id);
            my $report = $self->schema->resultset('Report')->find($report_id);
            return if !$report;

            return _report_transition_hash($report)
              if ( _column( $report, 'assigned_moderator_user_id' ) || q{} ) eq
              $moderator_user_id;

            my $changes = { assigned_moderator_user_id => $moderator_user_id };
            $report->update($changes);
            my $assigned = { report_id => $report_id, %{$changes} };
            $self->_record_transition_event_and_audit(
                {
                    report     => $report,
                    event_type => 'report.assigned',
                    actor_id   => $moderator_user_id,
                    payload    => {
                        assigned_moderator_user_id => $moderator_user_id,
                    },
                }
            );

            return $assigned;
        }
    );
}

sub release_report ( $self, $report_id, $actor_user_id ) {
    return $self->schema->txn_do(
        sub {
            $self->_lock_report($report_id);
            my $report = $self->schema->resultset('Report')->find($report_id);
            return if !$report;

            return _report_transition_hash($report)
              if !defined _column( $report, 'assigned_moderator_user_id' );

            my $changes = { assigned_moderator_user_id => undef };
            $report->update($changes);
            my $released = { report_id => $report_id, %{$changes} };
            $self->_record_transition_event_and_audit(
                {
                    report     => $report,
                    event_type => 'report.released',
                    actor_id   => $actor_user_id,
                    payload    => {
                        assigned_moderator_user_id => undef,
                    },
                }
            );

            return $released;
        }
    );
}

sub resolve_report ( $self, $report_id, $resolution, $actor_user_id = undef ) {
    return $self->schema->txn_do(
        sub {
            $self->_lock_report($report_id);
            my $report = $self->schema->resultset('Report')->find($report_id);
            return if !$report;

            return _report_transition_hash($report)
              if ( _column( $report, 'status' ) || q{} ) eq $STATUS_RESOLVED;

            my $resolved_at = $self->clock->now_iso8601;
            my $changes     = {
                status      => $STATUS_RESOLVED,
                resolved_at => $resolved_at,
                resolution  => $resolution,
            };
            $report->update($changes);
            my $resolved = { report_id => $report_id, %{$changes} };
            $self->_record_transition_event_and_audit(
                {
                    report     => $report,
                    event_type => 'report.resolved',
                    actor_id   => $actor_user_id,
                    payload    => {
                        resolution  => $resolution,
                        resolved_at => $resolved_at,
                    },
                }
            );

            return $resolved;
        }
    );
}

sub list_queue ( $self, $options ) {
    return [ _rows( $self->queue_resultset($options) ) ];
}

# The resultset the moderation queue executes.
# Public so the query-plan evidence EXPLAINs what actually runs.
sub queue_resultset ( $self, $options ) {
    return $self->schema->resultset('Report')->search_rs(
        {
            status => $options->{status} || $STATUS_OPEN,
        },
        {
            order_by => [ { -asc => 'created_at' }, { -asc => 'report_id' } ],
            rows     => $options->{limit} || $DEFAULT_QUEUE_LIMIT,
        }
    );
}

sub _report_transition_hash ($report) {
    return {
        assigned_moderator_user_id =>
          _column( $report, 'assigned_moderator_user_id' ),
        report_id   => _column( $report, 'report_id' ),
        resolution  => _column( $report, 'resolution' ),
        resolved_at => _column( $report, 'resolved_at' ),
        status      => _column( $report, 'status' ),
    };
}

sub _record_event_and_audit ( $self, $report ) {
    my $recorded = {
        correlation_id => $self->id_service->uuid,
        report         => $report,
    };
    $self->recorder->record_event(
        %{ $self->events->report_created_envelope($recorded) } );
    $self->recorder->record_audit(
        %{ $self->events->report_created_audit($recorded) } );

    return;
}

sub _record_transition_event_and_audit ( $self, $input ) {
    my $recorded = {
        %{$input},
        correlation_id => $self->id_service->uuid,
        created_at     => $self->clock->now_iso8601,
        event_id       => $self->id_service->uuid,
    };
    $self->recorder->record_event(
        %{ $self->events->report_transition_envelope($recorded) } );
    $self->recorder->record_audit(
        %{
            $self->events->report_transition_audit(
                {
                    action         => $input->{event_type},
                    actor_id       => $input->{actor_id},
                    correlation_id => $recorded->{correlation_id},
                    created_at     => $recorded->{created_at},
                    metadata       => $input->{payload},
                    report         => $input->{report},
                }
            )
        }
    );

    return;
}

sub _lock_report ( $self, $report_id ) {
    my $dbh = GPForum::Infrastructure::Storage->dbh_of( $self->schema );
    if ( !$dbh ) {
        return;
    }

    $dbh->selectrow_array( $REPORT_LOCK_SQL, undef, $report_id );

    return;
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

1;

__END__

=head1 NAME

GPForum::Service::Moderation::ReportStore - Member reports and their way through the moderation queue.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Moderation::ReportStore->new(
        schema => $schema,
    );
    my $report = $store->create_report(
        {
            reporter_user_id => $user_id,
            target_type      => 'post',
            target_id        => $post_id,
            reason           => 'spam',
            details          => 'link farm',
        }
    );
    my $queue = $store->list_queue( { status => 'open', limit => 50 } );
    $store->assign_report( $report_id, $moderator_id );
    $store->resolve_report( $report_id, 'removed', $moderator_id );

=head1 DESCRIPTION

Writes the C<reports> table and records, in the same transaction, a domain
event and an audit entry for each change, built by
L<GPForum::Service::Moderation::Event> and written by
L<GPForum::Infrastructure::EventRecorder>.

A member has at most one open or triaged report per target. Reporting the
same target again returns that report instead of a new one and audits the
attempt as C<report.duplicate_blocked>. If the existing report has no
C<report.created> event yet -- a report left over from a write that did
not finish -- its event and audit are recorded instead. A new report is
inserted inside a savepoint; when the insert loses a race on the open-report
index (C<idx_reports_reporter_target_open_unique>), the other writer's
report is reused the same way, and when it collides on the report id
(C<reports_pkey>), the report is looked up again and, when there is still
none, the insert is retried once with a fresh id.

Assigning, releasing and resolving lock the report row with
C<SELECT ... FOR UPDATE> first, when the schema has a database handle. A
transition that would change nothing writes nothing and records no event.

=head1 SUBROUTINES/METHODS

=head2 create_report

Takes a hash reference with C<reporter_user_id>, C<target_type>,
C<target_id>, C<reason> and an optional C<details> (empty when omitted).
Returns a hash reference of the new C<open> report's columns, or, when the
member already has an open or triaged report on that target, that report's
row.

=head2 assign_report

Takes a report id and a moderator's user id. Assigns the report to that
moderator and records C<report.assigned>, with the moderator as actor.
Returns C<< { report_id, assigned_moderator_user_id } >>; when it is
already assigned to that moderator, a hash reference of the report's
C<report_id>, C<status>, C<assigned_moderator_user_id>, C<resolution> and
C<resolved_at> instead. Returns an empty list (undef in scalar context)
when there is no such report.

=head2 release_report

Takes a report id and the acting user's id. Clears the assignment and
records C<report.released>. Returns
C<< { report_id, assigned_moderator_user_id => undef } >>; when the report
is not assigned, the report's state hash as for C<assign_report>. Returns
an empty list (undef in scalar context) when there is no such report.

=head2 resolve_report

Takes a report id, a resolution and, optionally, the acting user's id.
Sets the status to C<resolved> with C<resolved_at> and the resolution, and
records C<report.resolved>. Returns
C<< { report_id, status, resolved_at, resolution } >>; when the report is
already resolved, the report's state hash as for C<assign_report>. Returns
an empty list (undef in scalar context) when there is no such report.

=head2 list_queue

Takes a hash reference of the options C<queue_resultset> takes. Returns an
array reference of the report rows.

=head2 queue_resultset

Takes a hash reference with optional C<status> (default C<open>) and
C<limit> (default 50). Returns the unexecuted C<Report> resultset of the
reports in that status, oldest first, ordered by C<created_at> and then
C<report_id>. Public so the query-plan evidence EXPLAINs what actually
runs.

=head1 DIAGNOSTICS

C<create_report> croaks with the database error when the insert fails for
any reason other than a unique conflict, when an open-report conflict
leaves no report to reuse, and when the retry after an id collision fails
too. Every write runs in C<txn_do>, so a failure, including a failure to
record the event or the audit entry, rolls the whole change back and
propagates.

=head1 CONFIGURATION AND ENVIRONMENT

None. C<clock>, C<id_service>, C<recorder> and C<events> have defaults;
tests pass their own.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::EventRecorder>, L<GPForum::Infrastructure::Id>,
L<GPForum::Infrastructure::Row>, L<GPForum::Infrastructure::Storage>,
L<GPForum::Infrastructure::UniqueConflict>, L<GPForum::X::Conflict>,
L<GPForum::Service::Clock>, L<GPForum::Service::Moderation::Event>.

Extends L<GPForum::Base>: built without C<schema> it throws
L<GPForum::X::Argument>.

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
