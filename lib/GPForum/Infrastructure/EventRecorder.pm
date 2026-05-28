package GPForum::Infrastructure::EventRecorder;

use strict;
use warnings;

use POSIX qw(strftime);

use Const::Fast;
use Mojo::Base -base;

use GPForum::Domain::EventEnvelope;
use GPForum::Service::Id;
use GPForum::Service::Outbox::MessageBuilder;

our $VERSION = '0.001';

const my $DEFAULT_SCHEMA_VERSION => 1;

has envelope       => sub { return GPForum::Domain::EventEnvelope->new; };
has id_service     => sub { return GPForum::Service::Id->new; };
has outbox_builder => sub {
    my ($self) = @_;

    return GPForum::Service::Outbox::MessageBuilder->new(
        id_service => $self->id_service, );
};
has schema => undef;

sub record_event {
    my ( $self, %input ) = @_;

    my $event = $self->envelope->record(
        %input,
        event_id       => $input{event_id}       || $self->id_service->uuid,
        correlation_id => $input{correlation_id} || $self->id_service->uuid,
        schema_version => $input{schema_version} || $DEFAULT_SCHEMA_VERSION,
        timestamp      => $input{timestamp}      || _timestamp(),
    );

    $self->schema->resultset('EventLog')->create($event);
    $self->schema->resultset('OutboxMessage')
      ->create( $self->outbox_builder->for_event($event) );

    return $event;
}

sub record_audit {
    my ( $self, %input ) = @_;

    my $audit = {
        audit_id       => $input{audit_id} || $self->id_service->uuid,
        action         => $input{action},
        schema_version => $input{schema_version} || $DEFAULT_SCHEMA_VERSION,
        actor_id       => $input{actor_id},
        target_type    => $input{target_type},
        target_id      => $input{target_id},
        correlation_id => $input{correlation_id} || $self->id_service->uuid,
        previous_hash  => $input{previous_hash},
        record_hash    => $input{record_hash} || q{},
        metadata       => $input{metadata}    || {},
    };
    $audit->{created_at} = $input{created_at}
      if defined $input{created_at} && length $input{created_at};

    $self->schema->resultset('AuditLog')->create($audit);

    return $audit;
}

sub _timestamp {
    return strftime '%Y-%m-%dT%H:%M:%SZ', gmtime time;
}

1;
