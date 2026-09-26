# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Infrastructure::EventRecorder;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use JSON::MaybeXS;
use Mojo::Base -base, -signatures;

use GPForum::Domain::EventEnvelope;
use GPForum::Infrastructure::AuditRecord;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Infrastructure::OutboxMessageBuilder;

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
    require GPForum::Infrastructure::Id;
    return GPForum::Infrastructure::Id->new;
};
has outbox_builder => sub {
    my ($self) = @_;

    return GPForum::Infrastructure::OutboxMessageBuilder->new(
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

sub record_event ( $self, %input ) {
    my $outbox_payload = delete $input{outbox_payload};
    my $event          = $self->_recorded_event( \%input );

    return $self->_reuse_or_insert_event( $event, $outbox_payload );
}

# Whether the log holds an event with this idempotency key. A command that
# stored its row and failed before its event was recorded finishes, on
# replay, by recording the event -- once, and only if this says it is
# missing. ADR 0091's append_once: six stores each had their own copy.
sub event_recorded ( $self, $idempotency_key ) {
    my $search = $self->schema->resultset('EventLog')->search_rs(
        { idempotency_key => $idempotency_key },
        { rows            => $ROW_LIMIT_ONE },
    );

    return _first_row($search) ? 1 : 0;
}

sub _recorded_event ( $self, $input ) {
    return $self->envelope->record(
        %{$input},
        correlation_id => $input->{correlation_id} || $self->id_service->uuid,
        event_id       => $input->{event_id}       || $self->id_service->uuid,
        schema_version => $input->{schema_version} || $DEFAULT_SCHEMA_VERSION,
        timestamp => $input->{timestamp} || $self->audit_record->now_iso8601,
    );
}

sub _reuse_or_insert_event ( $self, $event, $outbox_payload ) {
    my $existing = $self->_existing_event($event);
    if ($existing) {
        return $self->_skipped_with_outbox( $existing, $outbox_payload );
    }

    return $self->_insert_event_and_outbox( $event, $outbox_payload );
}

sub _skipped_with_outbox ( $self, $existing, $outbox_payload ) {
    $self->_ensure_outbox( $existing, $outbox_payload );

    return _skipped_event($existing);
}

sub _insert_event_and_outbox ( $self, $event, $outbox_payload ) {
    my $stored = $self->_insert_or_retry_event($event);
    $self->_ensure_outbox( $stored, $outbox_payload );

    return $stored;
}

sub _insert_or_retry_event ( $self, $event ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_event($event); },
      );
    if ($created) {
        return $created;
    }

    return $self->_event_after_conflict( $event, $error );
}

sub _insert_event ( $self, $event ) {
    $self->schema->resultset('EventLog')->create($event);

    return $event;
}

sub _event_after_conflict ( $self, $event, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( index( $error, $EVENT_ID_CONSTRAINT ) < 0 ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_or_reuse_event($event);
}

sub _retry_or_reuse_event ( $self, $event ) {
    my $stored = $self->_existing_event($event);
    if ( $self->_same_open_event( $stored, $event ) ) {
        return _skipped_event($stored);
    }

    return $self->_retry_event_id($event);
}

sub _same_open_event ( $self, $stored, $event ) {
    my $copy = _event_hash($stored);
    if ( !exists $copy->{idempotency_key} ) {
        return 0;
    }
    if ( !exists $event->{idempotency_key} ) {
        return 0;
    }

    return _same_text( $copy->{idempotency_key}, $event->{idempotency_key} );
}

sub _retry_event_id ( $self, $event ) {
    my $retry = $self->_event_with_new_id($event);
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_event($retry); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _event_with_new_id ( $self, $event ) {
    my $event_id = $self->id_service->uuid;

    return {
        %{$event},
        event_id => $event_id,
        metadata => _metadata_with_event_id( $event->{metadata}, $event_id ),
    };
}

sub _metadata_with_event_id ( $metadata, $event_id ) {
    if ( ref $metadata ne 'HASH' ) {
        return { event_id => $event_id };
    }

    return { %{$metadata}, event_id => $event_id };
}

sub _same_text ( $stored, $candidate ) {
    if ( !defined $stored || !defined $candidate ) {
        return 0;
    }

    return $stored eq $candidate ? 1 : 0;
}

sub _ensure_outbox ( $self, $event, $outbox_payload ) {
    my $existing = $self->_existing_outbox($event);
    if ($existing) {
        return $existing;
    }

    return $self->_insert_or_reuse_outbox( $event, $outbox_payload );
}

sub _insert_or_reuse_outbox ( $self, $event, $outbox_payload ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_outbox( $event, $outbox_payload ); },
      );
    if ($created) {
        return $created;
    }

    return $self->_outbox_after_conflict( $event, $outbox_payload, $error );
}

sub _outbox_after_conflict ( $self, $event, $outbox_payload, $error ) {
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

sub _retry_or_reuse_outbox ( $self, $event, $outbox_payload ) {
    my $existing = $self->_existing_outbox($event);
    if ($existing) {
        return $existing;
    }

    return $self->_retry_outbox_id( $event, $outbox_payload );
}

sub _retry_outbox_id ( $self, $event, $outbox_payload ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_outbox( $event, $outbox_payload ); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _reuse_outbox ( $self, $event ) {
    my $existing = $self->_existing_outbox($event);
    if ($existing) {
        return $existing;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow(
        'outbox_messages_idempotency_key_key');
    return;
}

sub _insert_outbox ( $self, $event, $outbox_payload ) {
    my $row = $self->outbox_builder->for_event( $event, $outbox_payload );
    $self->schema->resultset('OutboxMessage')->create($row);

    return $row;
}

# The stored event as the same hash a new one is: the reuse and outbox paths
# read its fields by key. They were handed the DBIx::Class row, whose fields
# are not hash keys -- only the test doubles returned hashes -- so against
# PostgreSQL a retried event looked empty and its outbox row was built with
# no event_id.
sub _existing_event ( $self, $event ) {
    my $row = $self->schema->resultset('EventLog')
      ->find( { event_id => $event->{event_id} } );
    return      if !$row;
    return $row if ref $row eq 'HASH';

    return { $row->get_inflated_columns };
}

sub _existing_outbox ( $self, $event ) {
    my $search = $self->schema->resultset('OutboxMessage')->search_rs(
        { idempotency_key => _outbox_idempotency_key($event) },
        { rows            => $ROW_LIMIT_ONE },
    );

    return _first_row($search);
}

sub _outbox_idempotency_key ($event) {
    return GPForum::Infrastructure::OutboxMessageBuilder::idempotency_key_for(
        $event);
}

sub _first_row ($search) {
    if ( $search && $search->can('single') ) {
        return $search->single;
    }

    return;
}

sub _skipped_event ($existing) {
    return { %{ _event_hash($existing) }, skipped => 1 };
}

sub _event_hash ($event) {
    if ( ref $event eq 'HASH' ) {
        return $event;
    }

    return {};
}

sub record_audit ( $self, %input ) {
    my $work = sub {
        $self->_lock_audit_chain;

        return $self->_insert_or_retry_audit( \%input );
    };

    return $self->_audit_transaction($work);
}

# pg_advisory_xact_lock is released at the end of the holding transaction, so
# the lock, the latest-hash read, and the insert have to share one. Callers
# already inside txn_do keep that transaction; autocommit callers get one here.
sub _audit_transaction ( $self, $work ) {
    if ( $self->_needs_audit_transaction ) {
        return $self->schema->txn_do($work);
    }

    return $work->();
}

sub _needs_audit_transaction ($self) {
    if ( !$self->schema->can('txn_do') ) {
        return 0;
    }

    my $depth = $self->_audit_txn_depth;
    if ( !defined $depth ) {
        return 0;
    }

    return $depth ? 0 : 1;
}

sub _audit_txn_depth ($self) {
    my $storage = eval { return $self->schema->storage; };
    if ( !$storage || !$storage->can('txn_depth') ) {
        return;
    }

    return eval { return $storage->txn_depth; };
}

sub _insert_or_retry_audit ( $self, $input ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_audit($input); },
      );
    if ($created) {
        return $created;
    }

    return $self->_audit_after_conflict( $input, $error );
}

sub _insert_audit ( $self, $input ) {
    my $audit = $self->audit_record->build( $input, $self->_latest_audit_hash );
    $self->schema->resultset('AuditLog')->create($audit);

    return $audit;
}

sub _audit_after_conflict ( $self, $input, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }
    if ( index( $error, $AUDIT_ID_CONSTRAINT ) < 0 ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_audit_id($input);
}

sub _retry_audit_id ( $self, $input ) {
    my %retry = ( %{$input}, audit_id => $self->id_service->uuid );
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_audit( \%retry ); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub verify_audit_record ( $self, $audit ) {
    return $self->audit_record->verify($audit);
}

sub _latest_audit_hash ($self) {
    my $created_hash = $self->_latest_created_audit_hash;
    if ( $self->audit_record->has_text($created_hash) ) {
        return $created_hash;
    }

    return $self->_latest_persisted_audit_hash;
}

sub _lock_audit_chain ($self) {
    my $dbh = _schema_dbh( $self->schema );
    if ( !$dbh ) {
        return;
    }

    $dbh->selectrow_array( 'SELECT pg_advisory_xact_lock(?)',
        undef, $AUDIT_CHAIN_LOCK_KEY );

    return;
}

sub _latest_persisted_audit_hash ($self) {
    my $resultset = $self->schema->resultset('AuditLog');
    if ( !$resultset->can('search') ) {
        return;
    }

    my $latest = $resultset->search_rs(
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

sub _schema_dbh ($schema) {
    my $storage = eval { return $schema->storage; };
    if ( !$storage || !$storage->can('dbh') ) {
        return;
    }

    my $dbh = eval { return $storage->dbh; };
    return $dbh;
}

sub _latest_created_audit_hash ($self) {
    if ( !$self->schema->can('created_for') ) {
        return;
    }

    return $self->_newest_created_hash;
}

sub _newest_created_hash ($self) {
    my $audits = $self->schema->created_for('AuditLog');
    for my $audit ( reverse @{$audits} ) {
        my $hash = $self->_row_hash($audit);
        if ($hash) {
            return $hash;
        }
    }

    return;
}

sub _row_hash ( $self, $row ) {
    my $hash = $self->audit_record->column( $row, 'record_hash' );
    if ( !$self->audit_record->has_text($hash) ) {
        return;
    }

    return $hash;
}

1;
