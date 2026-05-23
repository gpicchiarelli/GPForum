package GPForum::Service::Moderation::ReportStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Service::Clock;
use GPForum::Service::Id;

our $VERSION = '0.001';

const my $DEFAULT_QUEUE_LIMIT => 50;
const my $STATUS_OPEN         => 'open';
const my $STATUS_RESOLVED     => 'resolved';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub create_report {
    my ( $self, $input ) = @_;

    my $report = {
        report_id                  => $self->id_service->uuid,
        reporter_user_id           => $input->{reporter_user_id},
        target_type                => $input->{target_type},
        target_id                  => $input->{target_id},
        reason                     => $input->{reason},
        details                    => $input->{details} || q{},
        status                     => $STATUS_OPEN,
        assigned_moderator_user_id => undef,
        created_at                 => $self->clock->now_iso8601,
        resolved_at                => undef,
        resolution                 => undef,
    };

    $self->schema->resultset('Report')->create($report);

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

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;
