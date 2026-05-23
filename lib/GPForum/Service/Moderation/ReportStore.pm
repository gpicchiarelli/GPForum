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
            return $self->_insert_report($input);
        }
    );
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

    my $report  = $self->schema->resultset('Report')->find($report_id);
    my $changes = { assigned_moderator_user_id => $moderator_user_id };
    $report->update($changes);

    return { report_id => $report_id, %{$changes} };
}

sub resolve_report {
    my ( $self, $report_id, $resolution ) = @_;

    my $report      = $self->schema->resultset('Report')->find($report_id);
    my $resolved_at = $self->clock->now_iso8601;
    my $changes     = {
        status      => $STATUS_RESOLVED,
        resolved_at => $resolved_at,
        resolution  => $resolution,
    };
    $report->update($changes);

    return { report_id => $report_id, %{$changes} };
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

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
