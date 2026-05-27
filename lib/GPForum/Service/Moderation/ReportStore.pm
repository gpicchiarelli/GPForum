package GPForum::Service::Moderation::ReportStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;
use GPForum::Service::Outbox::MessageBuilder;

our $VERSION = '0.001';

const my $DEFAULT_QUEUE_LIMIT => 50;
const my $REPORT_AGGREGATE    => 'report';
const my $SCHEMA_VERSION      => 1;
const my $STATUS_OPEN         => 'open';
const my $STATUS_RESOLVED     => 'resolved';

has clock          => sub { return GPForum::Service::Clock->new; };
has id_service     => sub { return GPForum::Service::Id->new; };
has outbox_builder => sub {
    my ($self) = @_;

    return GPForum::Service::Outbox::MessageBuilder->new(
        id_service => $self->id_service, );
};
has schema => undef;

sub create_report {
    my ( $self, $input ) = @_;

    return $self->schema->txn_do(
        sub {
            my $duplicate = $self->_open_duplicate_report($input);
            if ($duplicate) {
                $self->_record_duplicate_audit( $input, $duplicate );
                return $duplicate;
            }

            return $self->_insert_report($input);
        }
    );
}

sub _open_duplicate_report {
    my ( $self, $input ) = @_;

    return $self->schema->resultset('Report')->search(
        {
            reporter_user_id => $input->{reporter_user_id},
            target_type      => $input->{target_type},
            target_id        => $input->{target_id},
            status           => $STATUS_OPEN,
        },
        {
            order_by => { -desc => 'created_at' },
            rows     => 1,
        }
    )->single;
}

sub _record_duplicate_audit {
    my ( $self, $input, $duplicate ) = @_;

    $self->schema->resultset('AuditLog')->create(
        {
            audit_id       => $self->id_service->uuid,
            action         => 'report.duplicate_blocked',
            schema_version => $SCHEMA_VERSION,
            actor_id       => $input->{reporter_user_id},
            target_type    => $input->{target_type},
            target_id      => $input->{target_id},
            correlation_id => $self->id_service->uuid,
            previous_hash  => undef,
            record_hash    => q{},
            metadata       => {
                existing_report_id => _column( $duplicate, 'report_id' ),
                reason             => $input->{reason},
            },
            created_at => $self->clock->now_iso8601,
        }
    );

    return;
}

sub _insert_report {
    my ( $self, $input ) = @_;

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

sub assign_report {
    my ( $self, $report_id, $moderator_user_id ) = @_;

    return $self->schema->txn_do(
        sub {
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

sub release_report {
    my ( $self, $report_id, $actor_user_id ) = @_;

    return $self->schema->txn_do(
        sub {
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

sub resolve_report {
    my ( $self, $report_id, $resolution, $actor_user_id ) = @_;

    return $self->schema->txn_do(
        sub {
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

sub list_queue {
    my ( $self, $options ) = @_;

    my $search = $self->schema->resultset('Report')->search(
        {
            status => $options->{status} || $STATUS_OPEN,
        },
        {
            order_by => [ { -asc => 'created_at' }, { -asc => 'report_id' } ],
            rows     => $options->{limit} || $DEFAULT_QUEUE_LIMIT,
        }
    );

    return [ _rows($search) ];
}

sub _report_transition_hash {
    my ($report) = @_;

    return {
        assigned_moderator_user_id =>
          _column( $report, 'assigned_moderator_user_id' ),
        report_id   => _column( $report, 'report_id' ),
        resolution  => _column( $report, 'resolution' ),
        resolved_at => _column( $report, 'resolved_at' ),
        status      => _column( $report, 'status' ),
    };
}

sub _record_event_and_audit {
    my ( $self, $report ) = @_;

    my $correlation_id = $self->id_service->uuid;
    my $event_id       = $self->id_service->uuid;
    my $event          = {
        event_id          => $event_id,
        event_type        => 'report.created',
        schema_version    => $SCHEMA_VERSION,
        aggregate_type    => $REPORT_AGGREGATE,
        aggregate_id      => $report->{report_id},
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $report->{reporter_user_id},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key => join( q{:}, 'report.created', $report->{report_id} ),
        payload         => {
            report_id   => $report->{report_id},
            target_type => $report->{target_type},
            target_id   => $report->{target_id},
            reason      => $report->{reason},
        },
        metadata   => {},
        created_at => $report->{created_at},
    };

    $self->schema->resultset('EventLog')->create($event);
    $self->schema->resultset('OutboxMessage')
      ->create( $self->outbox_builder->for_event($event) );
    $self->_record_audit( $report, $correlation_id );

    return;
}

sub _record_audit {
    my ( $self, $report, $correlation_id ) = @_;

    $self->schema->resultset('AuditLog')->create(
        {
            audit_id       => $self->id_service->uuid,
            action         => 'report.created',
            schema_version => $SCHEMA_VERSION,
            actor_id       => $report->{reporter_user_id},
            target_type    => $report->{target_type},
            target_id      => $report->{target_id},
            correlation_id => $correlation_id,
            previous_hash  => undef,
            record_hash    => q{},
            metadata       => {
                reason    => $report->{reason},
                report_id => $report->{report_id},
            },
            created_at => $report->{created_at},
        }
    );

    return;
}

sub _record_transition_event_and_audit {
    my ( $self, $input ) = @_;

    my $report         = $input->{report};
    my $report_id      = _column( $report, 'report_id' );
    my $correlation_id = $self->id_service->uuid;
    my $event_id       = $self->id_service->uuid;
    my $created_at     = $self->clock->now_iso8601;
    my $event          = {
        event_id          => $event_id,
        event_type        => $input->{event_type},
        schema_version    => $SCHEMA_VERSION,
        aggregate_type    => $REPORT_AGGREGATE,
        aggregate_id      => $report_id,
        aggregate_version => $SCHEMA_VERSION,
        actor_id          => $input->{actor_id},
        correlation_id    => $correlation_id,
        causation_id      => undef,
        idempotency_key   =>
          join( q{:}, $input->{event_type}, $report_id, $event_id ),
        payload => {
            report_id   => $report_id,
            target_type => _column( $report, 'target_type' ),
            target_id   => _column( $report, 'target_id' ),
            %{ $input->{payload} },
        },
        metadata   => {},
        created_at => $created_at,
    };

    $self->schema->resultset('EventLog')->create($event);
    $self->schema->resultset('OutboxMessage')
      ->create( $self->outbox_builder->for_event($event) );
    $self->_record_transition_audit(
        {
            action         => $input->{event_type},
            actor_id       => $input->{actor_id},
            correlation_id => $correlation_id,
            created_at     => $created_at,
            metadata       => $input->{payload},
            report         => $report,
        }
    );

    return;
}

sub _record_transition_audit {
    my ( $self, $input ) = @_;

    my $report = $input->{report};

    $self->schema->resultset('AuditLog')->create(
        {
            audit_id       => $self->id_service->uuid,
            action         => $input->{action},
            schema_version => $SCHEMA_VERSION,
            actor_id       => $input->{actor_id},
            target_type    => _column( $report, 'target_type' ),
            target_id      => _column( $report, 'target_id' ),
            correlation_id => $input->{correlation_id},
            previous_hash  => undef,
            record_hash    => q{},
            metadata       => {
                report_id => _column( $report, 'report_id' ),
                %{ $input->{metadata} },
            },
            created_at => $input->{created_at},
        }
    );

    return;
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _column {
    my ( $row, $name ) = @_;

    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    return;
}

1;
