# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Infrastructure::EventRecorder;

use Const::Fast;
use English qw(-no_match_vars);
use JSON::MaybeXS;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Domain::EventEnvelope;
use GPForum::Infrastructure::AuditRecord;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Infrastructure::OutboxMessageBuilder;

our $VERSION = '0.001';

const my $DEFAULT_SCHEMA_VERSION => 1;
const my $AUDIT_CHAIN_LOCK_KEY   => 2_026_060_210;
const my $EVENT_ID_LOCK_CLASS    => 2_026_100_310;
const my $ROW_LIMIT_ONE          => 1;
const my $OUTBOX_ID_CONSTRAINT   => 'outbox_messages_pkey';
const my $OUTBOX_KEY_CONSTRAINT  => 'outbox_messages_idempotency_key_key';
const my $AUDIT_ID_CONSTRAINT    => 'audit_log_pkey';
const my $EVENT_ID_CONSTRAINT    => 'event_log_pkey';

# Two int4 keys, a key space apart from the audit chain's single bigint one:
# the class names the lock, hashtext the id. Two ids that hash alike only
# wait for each other.
const my $EVENT_ID_LOCK_SQL =>
  'SELECT pg_advisory_xact_lock(?, hashtext(?::text))';

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
    if ( !$self->audit_record->has_text( $input{event_id} ) ) {
        return $self->_reuse_or_insert_event( $event, $outbox_payload );
    }

    return $self->_in_transaction(
        sub {
            $self->_lock_event_id( $event->{event_id} );

            return $self->_reuse_or_insert_event( $event, $outbox_payload );
        }
    );
}

# ADR 0116. event_log_pkey is (event_id, created_at), so an event stored
# under this id at another time is no conflict for the insert: only the
# lookup by id, which reads every partition, finds it. A caller's own id can
# be written by another worker at the same moment, each at its own clock;
# both lookups would miss the other's uncommitted row and both inserts
# would succeed. The lock, held to the end of the transaction, puts the
# second lookup after the first commit; at READ COMMITTED, which every
# transaction here runs at, that lookup is a statement of its own and sees
# the commit. An id minted here is known to no one else and needs neither.
sub _lock_event_id ( $self, $event_id ) {
    my $dbh = _schema_dbh( $self->schema );
    if ( !$dbh ) {
        return;
    }

    $dbh->selectrow_array( $EVENT_ID_LOCK_SQL, undef, $EVENT_ID_LOCK_CLASS,
        $event_id );

    return;
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
    if ( !$self->_log_id_conflict( $error, $EVENT_ID_CONSTRAINT ) ) {
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

        return $self->_insert_or_retry_audit(
            $self->_audit_with_free_id( \%input ) );
    };

    return $self->_in_transaction($work);
}

# pg_advisory_xact_lock is released at the end of the holding transaction, so
# the lock, the reads it guards, and the insert have to share one. Callers
# already inside txn_do keep that transaction; autocommit callers get one here.
sub _in_transaction ( $self, $work ) {
    if ( $self->_needs_transaction ) {
        return $self->schema->txn_do($work);
    }

    return $work->();
}

sub _needs_transaction ($self) {
    if ( !$self->schema->can('txn_do') ) {
        return 0;
    }

    my $depth = $self->_txn_depth;
    if ( !defined $depth ) {
        return 0;
    }

    return $depth ? 0 : 1;
}

sub _txn_depth ($self) {
    my $storage = eval { return $self->schema->storage; };
    if ( !$storage || !$storage->can('txn_depth') ) {
        return;
    }

    return eval { return $storage->txn_depth; };
}

# ADR 0116. audit_log_pkey is (audit_id, created_at): a caller's audit id
# already stored at another time is no conflict for the insert, and was
# written a second time. It is looked up by id in every partition, under the
# chain lock every audit write already holds, and taken as the conflict on
# the key is: as a collision, written under a new id. An id the record mints
# itself is known to no one else and is not looked up.
sub _audit_with_free_id ( $self, $input ) {
    my $audit_id = $input->{audit_id};
    if ( !$self->audit_record->has_text($audit_id) ) {
        return $input;
    }
    if ( !$self->_audit_id_taken($audit_id) ) {
        return $input;
    }

    return { %{$input}, audit_id => $self->id_service->uuid };
}

sub _audit_id_taken ( $self, $audit_id ) {
    my $resultset = $self->schema->resultset('AuditLog');
    if ( !$resultset->can('search_rs') ) {
        return 0;
    }

    my $search = $resultset->search_rs( { audit_id => $audit_id },
        { columns => ['audit_id'], rows => $ROW_LIMIT_ONE } );

    return _first_row($search) ? 1 : 0;
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
    if ( !$self->_log_id_conflict( $error, $AUDIT_ID_CONSTRAINT ) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_retry_audit_id($input);
}

# event_log and audit_log are partitioned by created_at, and PostgreSQL names
# the partition's index in the conflict (event_log_default_pkey,
# audit_log_2026_10_pkey), never the table's constraint: matched on that name
# alone, every collision on PostgreSQL was rethrown -- a raced event was not
# reused and a colliding audit id was not minted again.
sub _log_id_conflict ( $self, $error, $constraint ) {
    return GPForum::Infrastructure::UniqueConflict->is_conflict_on(
        $self->schema, $error, $constraint );
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

__END__

=head1 NAME

GPForum::Infrastructure::EventRecorder - Appends events with their outbox rows, and hash-chained audit records.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $recorder = GPForum::Infrastructure::EventRecorder->new(
        schema => $schema );
    $schema->txn_do(
        sub {
            # ... the command's own rows ...
            return if $recorder->event_recorded($idempotency_key);
            $recorder->record_event(
                event_type        => 'thread.created',
                aggregate_type    => 'thread',
                aggregate_id      => $thread_id,
                aggregate_version => 1,
                actor_id          => $user_id,
                idempotency_key   => $idempotency_key,
                payload           => { thread_id => $thread_id },
                timestamp         => $created_at,
            );
            $recorder->record_audit(
                action      => 'thread.created',
                actor_id    => $user_id,
                target_type => 'thread',
                target_id   => $thread_id,
                created_at  => $created_at,
            );
        }
    );

=head1 DESCRIPTION

The one writer of C<event_log>, of the C<outbox_messages> row each event
gets, and of C<audit_log>. The stores call it inside their command's
transaction, so the event, its outbox row and the audit record commit or
roll back with the command's own rows.

An event is shaped by L<GPForum::Domain::EventEnvelope>; its outbox row by
L<GPForum::Infrastructure::OutboxMessageBuilder>, keyed by the event so a
retry does not queue it twice. An event already stored under its
C<event_id> is not written again: it is returned with C<skipped> set, and
its outbox row is added if it is missing. A unique conflict on the insert
is taken back in a savepoint (L<GPForum::Infrastructure::UniqueConflict>)
and resolved by reading the row that won.

C<event_log>, C<audit_log> and C<notifications> are partitioned by
C<created_at>, and their primary keys are the id and that time, so the key
does not catch an id stored at another time; the lookup by id, which reads
every partition, does (ADR 0116). An C<event_id> the caller passes is
looked up under a transaction advisory lock on that id, so two workers
writing it at once at different times cannot both miss the other. An id
minted here is known to no one else and is neither locked nor raced.

An audit record is built by L<GPForum::Infrastructure::AuditRecord>, its
C<previous_hash> the C<record_hash> of the newest record, under
C<pg_advisory_xact_lock(2026060210)>: the lock, the read of the chain's tip
and the insert share one transaction, the caller's or one opened here. An
C<audit_id> the caller passes that is already stored, at any time, is a
collision: the record is written under a newly minted id, as it is after a
conflict on the key.

=head1 SUBROUTINES/METHODS

=head2 record_event

Takes the event's fields as a list of pairs: C<event_type>,
C<aggregate_type>, C<aggregate_id>, C<aggregate_version>, C<actor_id>,
C<idempotency_key>, C<payload>, and optionally C<event_id>,
C<correlation_id> (both minted when absent), C<causation_id>,
C<schema_version> (default 1), C<timestamp> (the row's C<created_at>,
default now) and C<outbox_payload> (fields merged into the outbox row's
payload, and kept out of the event's). Returns the stored event as a hash
reference; one already stored under its C<event_id> comes back with
C<< skipped => 1 >>. An insert that conflicts on the id with an event of
another idempotency key is written again under a new C<event_id>, which
the returned event carries. Dies on any other database error, a unique
conflict on any other key included.

=head2 event_recorded

Takes an idempotency key. True when C<event_log> holds an event with it: a
command that stored its rows and died before its event replays by
recording the event once, if this says it is missing.

=head2 record_audit

Takes the audit record's fields as a list of pairs: C<action>, C<actor_id>,
C<target_type>, C<target_id>, C<metadata>, and optionally C<audit_id>,
C<correlation_id> (both minted when absent), C<schema_version> and
C<created_at> (default now). Chains it to the newest record, writes it, and
returns it as a hash reference with its C<previous_hash> and
C<record_hash>. Its C<audit_id> is a new one when the caller's was already
taken.

=head2 verify_audit_record

Takes an audit record, a hash reference or a row. True when its
C<record_hash> matches its fields.

=head1 DIAGNOSTICS

Database errors are rethrown as DBI raised them; a unique conflict on any
key but the row's own id is rethrown too.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables are read. The advisory locks are taken only
through a schema whose storage has a database handle; a test double without
one is written to without them.

=head1 DEPENDENCIES

Uses L<GPForum::Domain::EventEnvelope>,
L<GPForum::Infrastructure::AuditRecord>,
L<GPForum::Infrastructure::OutboxMessageBuilder>,
L<GPForum::Infrastructure::UniqueConflict>, L<JSON::MaybeXS>, and loads
L<GPForum::Infrastructure::Id> only when no C<id_service> is injected.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The lookup by id reads each partition's primary key index, so its cost
grows with the number of monthly partitions until their retention is
decided (ADR 0113).

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
