package GPForum::Infrastructure::EventRecorder;

use strict;
use warnings;

use POSIX qw(strftime);

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use JSON::MaybeXS;
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
has json   => sub { return JSON::MaybeXS->new( canonical => 1, utf8 => 1 ); };

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

    my $audit = $self->_audit_record(%input);

    $self->schema->resultset('AuditLog')->create($audit);

    return $audit;
}

sub _audit_record {
    my ( $self, %input ) = @_;

    my $audit = {
        audit_id       => $self->_audit_id(%input),
        action         => $input{action},
        schema_version => _audit_schema_version(%input),
        actor_id       => $input{actor_id},
        target_type    => $input{target_type},
        target_id      => $input{target_id},
        correlation_id => $self->_audit_correlation_id(%input),
        previous_hash  => scalar $self->_audit_previous_hash(%input),
        record_hash    => q{},
        metadata       => _audit_metadata(%input),
        created_at     => _audit_created_at(%input),
    };

    $audit->{record_hash} = $self->_audit_record_hash($audit);

    return $audit;
}

sub verify_audit_record {
    my ( $self, $audit ) = @_;

    my $audit_payload = _audit_record_payload($audit);
    my $hash          = $audit_payload->{record_hash};
    return 0 if !defined $hash || !length $hash;

    return $hash eq $self->_audit_record_hash($audit_payload) ? 1 : 0;
}

sub _audit_id {
    my ( $self, %input ) = @_;

    return $input{audit_id}
      if defined $input{audit_id} && length $input{audit_id};

    return $self->id_service->uuid;
}

sub _audit_schema_version {
    my (%input) = @_;

    return $input{schema_version}
      if defined $input{schema_version} && length $input{schema_version};

    return $DEFAULT_SCHEMA_VERSION;
}

sub _audit_correlation_id {
    my ( $self, %input ) = @_;

    return $input{correlation_id}
      if defined $input{correlation_id} && length $input{correlation_id};

    return $self->id_service->uuid;
}

sub _audit_metadata {
    my (%input) = @_;

    return $input{metadata} if defined $input{metadata};

    return {};
}

sub _audit_created_at {
    my (%input) = @_;

    return $input{created_at}
      if defined $input{created_at} && length $input{created_at};

    return _timestamp();
}

sub _audit_previous_hash {
    my ( $self, %input ) = @_;

    return $input{previous_hash}
      if defined $input{previous_hash} && length $input{previous_hash};

    return $self->_latest_audit_hash;
}

sub _latest_audit_hash {
    my ($self) = @_;

    my $created_hash = $self->_latest_created_audit_hash;
    return $created_hash if defined $created_hash && length $created_hash;

    return $self->_latest_persisted_audit_hash;
}

sub _latest_persisted_audit_hash {
    my ($self) = @_;

    my $resultset = eval { return $self->schema->resultset('AuditLog'); };
    return if !$resultset;

    my $latest = eval {
        return $resultset->search(
            {},
            {
                order_by =>
                  [ { -desc => 'created_at' }, { -desc => 'audit_id' }, ],
                rows => 1,
            }
        )->single;
    };
    return if !$latest;

    my $hash = _column( $latest, 'record_hash' );
    return defined $hash && length $hash ? $hash : undef;
}

sub _latest_created_audit_hash {
    my ($self) = @_;

    return if !$self->schema->can('created_for');

    my $audits = $self->schema->created_for('AuditLog');
    for my $audit ( reverse @{$audits} ) {
        my $hash = _column( $audit, 'record_hash' );
        return $hash if defined $hash && length $hash;
    }

    return;
}

sub _audit_record_hash {
    my ( $self, $audit ) = @_;

    my %canonical = %{$audit};
    delete $canonical{record_hash};

    return sha256_hex( $self->json->encode( \%canonical ) );
}

sub _audit_record_payload {
    my ($audit) = @_;

    return {
        audit_id       => _column( $audit, 'audit_id' ),
        action         => _column( $audit, 'action' ),
        schema_version => _column( $audit, 'schema_version' ),
        actor_id       => _column( $audit, 'actor_id' ),
        target_type    => _column( $audit, 'target_type' ),
        target_id      => _column( $audit, 'target_id' ),
        correlation_id => _column( $audit, 'correlation_id' ),
        previous_hash  => _column( $audit, 'previous_hash' ),
        record_hash    => _column( $audit, 'record_hash' ),
        metadata       => _column( $audit, 'metadata' ),
        created_at     => _column( $audit, 'created_at' ),
    };
}

sub _column {
    my ( $row, $name ) = @_;

    return                         if !$row;
    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row->can('get_column');

    return;
}

sub _timestamp {
    return strftime '%Y-%m-%dT%H:%M:%SZ', gmtime time;
}

1;
