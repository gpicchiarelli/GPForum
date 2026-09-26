# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Moderation::ReportStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Moderation::Event;

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
has schema => undef;
has events => sub { return GPForum::Service::Moderation::Event->new; };

sub create_report ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            my $duplicate = $self->_open_duplicate_report($input);
            if ($duplicate) {
                return $self->_finish_leftover_report( $duplicate, $input );
            }

            return $self->_insert_or_reuse($input);
        }
    );
}

sub _insert_or_reuse ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_report($input); },
      );
    if ($created) {
        return $created;
    }

    return $self->_duplicate_after_conflict( $input, $error );
}

sub _duplicate_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_report_after_unique( $input, $error );
}

sub _report_after_unique ( $self, $input, $error ) {
    if ( _report_id_conflict($error) ) {
        return $self->_report_after_id_conflict($input);
    }
    if ( _open_report_conflict($error) ) {
        return $self->_reuse_report_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _report_after_id_conflict ( $self, $input ) {
    my $duplicate = $self->_open_duplicate_report($input);
    if ($duplicate) {
        return $self->_finish_leftover_report( $duplicate, $input );
    }

    return $self->_retry_report_id($input);
}

sub _retry_report_id ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_report($input); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    my $undefined;
    return $undefined;
}

sub _reuse_report_row ( $self, $input, $error ) {
    my $duplicate = $self->_open_duplicate_report($input);
    if ( !$duplicate ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_finish_leftover_report( $duplicate, $input );
}

sub _report_id_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _open_report_conflict ($error) {
    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $OPEN_CONSTRAINT ) >= 0 ? 1 : 0;
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

sub _record_duplicate_audit ( $self, $input, $duplicate ) {
    $self->recorder->record_audit(
        %{
            $self->events->report_duplicate_audit(
                {
                    created_at       => $self->clock->now_iso8601,
                    duplicate        => $duplicate,
                    reason           => $input->{reason},
                    reporter_user_id => $input->{reporter_user_id},
                    target_id        => $input->{target_id},
                    target_type      => $input->{target_type},
                }
            )
        }
    );

    return;
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

sub _finish_leftover_report ( $self, $existing, $input ) {
    if ( $self->_report_event_exists($existing) ) {
        $self->_record_duplicate_audit( $input, $existing );
        return $existing;
    }

    $self->_record_event_and_audit($existing);

    return $existing;
}

sub _report_event_exists ( $self, $existing ) {
    return $self->recorder->event_recorded( join q{:}, 'report.created',
        _column( $existing, 'report_id' ) );
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
    my $dbh = _schema_dbh( $self->schema );
    if ( !$dbh ) {
        return;
    }

    $dbh->selectrow_array( $REPORT_LOCK_SQL, undef, $report_id );

    return;
}

sub _schema_dbh ($schema) {
    my $storage = eval { return $schema->storage; };
    if ( !$storage || !$storage->can('dbh') ) {
        my $undefined;
        return $undefined;
    }

    my $dbh = eval { return $storage->dbh; };
    return $dbh;
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
