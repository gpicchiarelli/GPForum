package GPForum::Infrastructure::EventRecorder;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use JSON::MaybeXS;
use Mojo::Base -base;

use GPForum::Domain::EventEnvelope;
use GPForum::Infrastructure::AuditRecord;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Outbox::MessageBuilder;

our $VERSION = '0.001';

const my $DEFAULT_SCHEMA_VERSION => 1;
const my $AUDIT_CHAIN_LOCK_KEY   => 2_026_060_210;
const my $ROW_LIMIT_ONE          => 1;
const my $OUTBOX_ID_CONSTRAINT   => 'outbox_messages_pkey';
const my $OUTBOX_KEY_CONSTRAINT  => 'outbox_messages_idempotency_key_key';
const my $AUDIT_ID_CONSTRAINT    => 'audit_log_pkey';
const my $EVENT_ID_CONSTRAINT    => 'event_log_pkey';

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

    my $outbox_payload = delete $input{outbox_payload};
    my $event          = $self->_recorded_event( \%input );

    return $self->_reuse_or_insert_event( $event, $outbox_payload );
}

sub _recorded_event {
    my ( $self, $input ) = @_;

    return $self->envelope->record(
        %{$input},
        correlation_id => $input->{correlation_id} || $self->id_service->uuid,
        event_id       => $input->{event_id}       || $self->id_service->uuid,
        schema_version => $input->{schema_version} || $DEFAULT_SCHEMA_VERSION,
        timestamp => $input->{timestamp} || $self->audit_record->now_iso8601,
    );
}

sub _reuse_or_insert_event {
    my ( $self, $event, $outbox_payload ) = @_;

    my $existing = $self->_existing_event($event);
    if ($existing) {
        return $self->_skipped_with_outbox( $existing, $outbox_payload );
    }

    return $self->_insert_event_and_outbox( $event, $outbox_payload );
}

sub _skipped_with_outbox {
    my ( $self, $existing, $outbox_payload ) = @_;

    $self->_ensure_outbox( $existing, $outbox_payload );

    return _skipped_event($existing);
}

sub _insert_event_and_outbox {
    my ( $self, $event, $outbox_payload ) = @_;

    my $stored = $self->_insert_or_retry_event($event);
    $self->_ensure_outbox( $stored, $outbox_payload );

    return $stored;
}

sub _insert_or_retry_event {
    my ( $self, $event ) = @_;

    my $created = eval { return $self->_insert_event($event); };
    if ($created) {
        return $created;
    }

    return $self->_event_after_conflict( $event, $EVAL_ERROR );
}

sub _insert_event {
    my ( $self, $event ) = @_;

    $self->schema->resultset('EventLog')->create($event);

    return $event;
}

sub _event_after_conflict {
    my ( $self, $event, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( index( $error, $EVENT_ID_CONSTRAINT ) < 0 ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_or_reuse_event($event);
}

sub _retry_or_reuse_event {
    my ( $self, $event ) = @_;

    my $stored = $self->_existing_event($event);
    if ( $self->_same_open_event( $stored, $event ) ) {
        return _skipped_event($stored);
    }

    return $self->_retry_event_id($event);
}

sub _same_open_event {
    my ( $self, $stored, $event ) = @_;

    my $copy = _event_hash($stored);
    if ( !exists $copy->{idempotency_key} ) {
        return 0;
    }
    if ( !exists $event->{idempotency_key} ) {
        return 0;
    }

    return _same_text( $copy->{idempotency_key}, $event->{idempotency_key} );
}

sub _retry_event_id {
    my ( $self, $event ) = @_;

    my $retry   = $self->_event_with_new_id($event);
    my $created = eval { return $self->_insert_event($retry); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _event_with_new_id {
    my ( $self, $event ) = @_;

    my $event_id = $self->id_service->uuid;

    return {
        %{$event},
        event_id => $event_id,
        metadata => _metadata_with_event_id( $event->{metadata}, $event_id ),
    };
}

sub _metadata_with_event_id {
    my ( $metadata, $event_id ) = @_;

    if ( ref $metadata ne 'HASH' ) {
        return { event_id => $event_id };
    }

    return { %{$metadata}, event_id => $event_id };
}

sub _same_text {
    my ( $stored, $candidate ) = @_;

    if ( !defined $stored || !defined $candidate ) {
        return 0;
    }

    return $stored eq $candidate ? 1 : 0;
}

sub _ensure_outbox {
    my ( $self, $event, $outbox_payload ) = @_;

    my $existing = $self->_existing_outbox($event);
    if ($existing) {
        return $existing;
    }

    return $self->_insert_or_reuse_outbox( $event, $outbox_payload );
}

sub _insert_or_reuse_outbox {
    my ( $self, $event, $outbox_payload ) = @_;

    my $created =
      eval { return $self->_insert_outbox( $event, $outbox_payload ); };
    if ($created) {
        return $created;
    }

    return $self->_outbox_after_conflict( $event, $outbox_payload,
        $EVAL_ERROR );
}

sub _outbox_after_conflict {
    my ( $self, $event, $outbox_payload, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( index( $error, $OUTBOX_ID_CONSTRAINT ) >= 0 ) {
        return $self->_retry_or_reuse_outbox( $event, $outbox_payload );
    }
    if ( index( $error, $OUTBOX_KEY_CONSTRAINT ) >= 0 ) {
        return $self->_reuse_outbox($event);
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _retry_or_reuse_outbox {
    my ( $self, $event, $outbox_payload ) = @_;

    my $existing = $self->_existing_outbox($event);
    if ($existing) {
        return $existing;
    }

    return $self->_retry_outbox_id( $event, $outbox_payload );
}

sub _retry_outbox_id {
    my ( $self, $event, $outbox_payload ) = @_;

    my $created =
      eval { return $self->_insert_outbox( $event, $outbox_payload ); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
}

sub _reuse_outbox {
    my ( $self, $event ) = @_;

    my $existing = $self->_existing_outbox($event);
    if ($existing) {
        return $existing;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow(
        'outbox_messages_idempotency_key_key');
    return;
}

sub _insert_outbox {
    my ( $self, $event, $outbox_payload ) = @_;

    my $row = $self->outbox_builder->for_event( $event, $outbox_payload );
    $self->schema->resultset('OutboxMessage')->create($row);

    return $row;
}

sub _existing_event {
    my ( $self, $event ) = @_;

    return $self->schema->resultset('EventLog')
      ->find( { event_id => $event->{event_id} } );
}

sub _existing_outbox {
    my ( $self, $event ) = @_;

    my $search = $self->schema->resultset('OutboxMessage')->search(
        { idempotency_key => _outbox_idempotency_key($event) },
        { rows            => $ROW_LIMIT_ONE },
    );

    return _first_row($search);
}

sub _outbox_idempotency_key {
    my ($event) = @_;

    return GPForum::Service::Outbox::MessageBuilder::idempotency_key_for(
        $event);
}

sub _first_row {
    my ($search) = @_;

    if ( $search && $search->can('single') ) {
        return $search->single;
    }

    return;
}

sub _skipped_event {
    my ($existing) = @_;

    return { %{ _event_hash($existing) }, skipped => 1 };
}

sub _event_hash {
    my ($event) = @_;

    if ( ref $event eq 'HASH' ) {
        return $event;
    }

    return {};
}

sub record_audit {
    my ( $self, %input ) = @_;

    $self->_lock_audit_chain;

    return $self->_insert_or_retry_audit( \%input );
}

sub _insert_or_retry_audit {
    my ( $self, $input ) = @_;

    my $created = eval { return $self->_insert_audit($input); };
    if ($created) {
        return $created;
    }

    return $self->_audit_after_conflict( $input, $EVAL_ERROR );
}

sub _insert_audit {
    my ( $self, $input ) = @_;

    my $audit = $self->audit_record->build( $input, $self->_latest_audit_hash );
    $self->schema->resultset('AuditLog')->create($audit);

    return $audit;
}

sub _audit_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( index( $error, $AUDIT_ID_CONSTRAINT ) < 0 ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_audit_id($input);
}

sub _retry_audit_id {
    my ( $self, $input ) = @_;

    my %retry   = ( %{$input}, audit_id => $self->id_service->uuid );
    my $created = eval { return $self->_insert_audit( \%retry ); };
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($EVAL_ERROR);
    return;
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

    my $resultset = $self->schema->resultset('AuditLog');
    if ( !$resultset->can('search') ) {
        return;
    }

    my $latest = $resultset->search(
        {},
        {
            order_by => [ { -desc => 'created_at' }, { -desc => 'audit_id' }, ],
            rows     => 1,
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
