package GPForum::Infrastructure::EventRecorder;

use strict;
use warnings;

use Const::Fast;
use JSON::MaybeXS;
use Mojo::Base -base;

use GPForum::Domain::EventEnvelope;
use GPForum::Infrastructure::AuditRecord;
use GPForum::Service::Outbox::MessageBuilder;

our $VERSION = '0.001';

const my $DEFAULT_SCHEMA_VERSION => 1;
const my $AUDIT_CHAIN_LOCK_KEY   => 2_026_060_210;

has envelope   => sub { return GPForum::Domain::EventEnvelope->new; };
has id_service => sub {
    require GPForum::Service::Id;
    return GPForum::Service::Id->new;
};
has outbox_builder => sub {
    my ($self) = @_;

    return GPForum::Service::Outbox::MessageBuilder->new(
        id_service => $self->id_service, );
};
has schema => undef;
has json   => sub { return JSON::MaybeXS->new( canonical => 1, utf8 => 1 ); };
has audit_record => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::AuditRecord->new(
        id_service => $self->id_service,
        json       => $self->json,
    );
};

sub record_event {
    my ( $self, %input ) = @_;

    my $event = $self->envelope->record(
        %input,
        correlation_id => $input{correlation_id} || $self->id_service->uuid,
        event_id       => $input{event_id}       || $self->id_service->uuid,
        schema_version => $input{schema_version} || $DEFAULT_SCHEMA_VERSION,
        timestamp      => $input{timestamp} || $self->audit_record->now_iso8601,
    );

    $self->schema->resultset('EventLog')->create($event);
    $self->schema->resultset('OutboxMessage')
      ->create( $self->outbox_builder->for_event($event) );

    return $event;
}

sub record_audit {
    my ( $self, %input ) = @_;

    $self->_lock_audit_chain;
    my $audit =
      $self->audit_record->build( \%input, $self->_latest_audit_hash );
    $self->schema->resultset('AuditLog')->create($audit);

    return $audit;
}

sub verify_audit_record {
    my ( $self, $audit ) = @_;

    return $self->audit_record->verify($audit);
}

sub _latest_audit_hash {
    my ($self) = @_;

    my $created_hash = $self->_latest_created_audit_hash;
    if ( $self->audit_record->has_text($created_hash) ) {
        return $created_hash;
    }

    return $self->_latest_persisted_audit_hash;
}

sub _lock_audit_chain {
    my ($self) = @_;

    my $dbh = _schema_dbh( $self->schema );
    if ( !$dbh ) {
        return;
    }

    $dbh->selectrow_array( 'SELECT pg_advisory_xact_lock(?)',
        undef, $AUDIT_CHAIN_LOCK_KEY );

    return;
}

sub _latest_persisted_audit_hash {
    my ($self) = @_;

    my $latest = $self->schema->resultset('AuditLog')->search(
        {},
        {
            order_by =>
              [ { -desc => 'created_at' }, { -desc => 'audit_id' }, ],
            rows => 1,
        }
    )->single;
    if ( !$latest ) {
        return;
    }

    return $self->_row_hash($latest);
}

sub _schema_dbh {
    my ($schema) = @_;

    my $storage = eval { return $schema->storage; };
    if ( !$storage || !$storage->can('dbh') ) {
        return;
    }

    my $dbh = eval { return $storage->dbh; };
    return $dbh;
}

sub _latest_created_audit_hash {
    my ($self) = @_;

    if ( !$self->schema->can('created_for') ) {
        return;
    }

    return $self->_newest_created_hash;
}

sub _newest_created_hash {
    my ($self) = @_;

    my $audits = $self->schema->created_for('AuditLog');
    for my $audit ( reverse @{$audits} ) {
        my $hash = $self->_row_hash($audit);
        if ($hash) {
            return $hash;
        }
    }

    return;
}

sub _row_hash {
    my ( $self, $row ) = @_;

    my $hash = $self->audit_record->column( $row, 'record_hash' );
    if ( !$self->audit_record->has_text($hash) ) {
        return;
    }

    return $hash;
}

1;
