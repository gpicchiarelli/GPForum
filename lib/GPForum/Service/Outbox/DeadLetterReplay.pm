# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Outbox::DeadLetterReplay;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::EventRecorder;
use GPForum::Infrastructure::Id;
use GPForum::Infrastructure::OutboxMessageBuilder;
use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $OUTBOX_TABLE   => 'outbox_messages';
const my $KEY_PREFIX     => 'dead-letter-replay:';
const my $AUDIT_ACTION   => 'outbox.dead_letter_replayed';
const my $AUDIT_TARGET   => 'dead_letter';
const my $SCHEMA_VERSION => 1;

has builder => sub ($self) {
    return GPForum::Infrastructure::OutboxMessageBuilder->new(
        id_service => $self->id_service );
};
has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
has recorder   => sub ($self) {
    return GPForum::Infrastructure::EventRecorder->new(
        id_service => $self->id_service,
        schema     => $self->schema,
    );
};
has schema => undef;

# The idempotency key of the message a replay enqueues, derived from the dead
# letter. If the replay fails in turn, it has its own dead letter.
sub replay_key ( $class, $dead_letter_id ) {
    return $KEY_PREFIX . $dead_letter_id;
}

# How a dead letter's replay is doing, as SQL for the row whose dead_letter_id
# is $column: the replay message's status while retention keeps it, then
# 'replayed' for as long as the dead letter lives. Retention purges a done
# message after seven days and keeps the dead letter for thirty, so the
# message alone would forget the replay. The audit log never does.
sub replay_status_sql ( $class, $column ) {
    return \[
        'COALESCE((SELECT replay.status FROM outbox_messages replay'
          . " WHERE replay.idempotency_key = ? || $column\::text),"
          . q{ (SELECT 'replayed' FROM audit_log replayed}
          . ' WHERE replayed.action = ? AND replayed.target_type = ?'
          . " AND replayed.target_id = $column LIMIT 1))",
        $KEY_PREFIX, $AUDIT_ACTION, $AUDIT_TARGET,
    ];
}

# Puts the work of a dead letter back in the queue (ADR 0056), once its cause
# is fixed. The cancelled message and the dead letter are evidence and stay as
# they are: the replay is a new outbox message carrying the dead letter's
# envelope, with the full retry budget, and the audit log records who asked
# for it and how. Built from the dead letter alone, it works for as long as
# the dead letter is kept -- thirty days -- not only the seven the cancelled
# message is.
sub replay ( $self, $input ) {
    my $dead_letter_id = $input->{dead_letter_id};
    if ( !GPForum::Infrastructure::Id->is_uuid($dead_letter_id) ) {
        return _refused( 'not_found', 'dead letter not found' );
    }

    return $self->schema->txn_do(
        sub { return $self->_replay_locked( $dead_letter_id, $input ); } );
}

# The dead letter's row lock serialises two operators replaying it at once;
# the second waits, then meets the first one's audit row.
sub _replay_locked ( $self, $dead_letter_id, $input ) {
    my $letter = $self->schema->resultset('DeadLetter')
      ->find( $dead_letter_id, { for => 'update' } );
    return _refused( 'not_found', 'dead letter not found' ) if !$letter;

    my $envelope = $letter->get_inflated_column('payload');
    my $refusal  = $self->_unreplayable( $letter, $envelope );
    return $refusal if $refusal;

    return $self->_enqueue( $letter, $envelope, $input );
}

sub _unreplayable ( $self, $letter, $envelope ) {
    if ( $letter->get_column('source_table') ne $OUTBOX_TABLE ) {
        return _refused( 'conflict',
            'only outbox dead letters can be replayed' );
    }
    if ( ref $envelope ne 'HASH'
        || !GPForum::Infrastructure::Id->is_uuid( $envelope->{event_id} ) )
    {
        return _refused( 'conflict',
                'the dead letter does not name its event; emit the work again'
              . ' from its source' );
    }

    # Asked of the audit log, not the replay message: retention purges a
    # delivered message after seven days, and the dead letter lives thirty.
    my $replays = $self->schema->resultset('AuditLog')->search_rs(
        {
            action      => $AUDIT_ACTION,
            target_id   => $letter->get_column('dead_letter_id'),
            target_type => $AUDIT_TARGET,
        },
        { columns => [qw(created_at metadata)], rows => 1 }
    );
    my $earlier = $replays->single;
    return if !$earlier;

    my $metadata = $earlier->get_inflated_column('metadata') || {};
    return _refused( 'conflict',
            'already replayed at '
          . $earlier->get_column('created_at')
          . ' as outbox '
          . ( $metadata->{outbox_id} // 'unknown' ) );
}

sub _enqueue ( $self, $letter, $envelope, $input ) {
    my $dead_letter_id = $letter->get_column('dead_letter_id');
    my $now            = $self->clock->now_iso8601;
    my $message =
      $self->builder->for_replay( $self->replay_key($dead_letter_id),
        $envelope );
    $self->schema->resultset('OutboxMessage')
      ->create( { %{$message}, next_attempt_at => $now } );

    my %replayed = (
        dead_letter_id => $dead_letter_id,
        event_id       => $message->{event_id},
        outbox_id      => $message->{outbox_id},
        source_id      => $letter->get_column('source_id'),
    );
    $self->recorder->record_audit(
        action         => $AUDIT_ACTION,
        actor_id       => $input->{actor_user_id},
        correlation_id => $self->id_service->uuid,
        created_at     => $now,
        metadata       => {
            %replayed,
            error_class  => $letter->get_column('error_class'),
            failure_type => $letter->get_column('failure_type'),
            retry_count  => $letter->get_column('retry_count'),
            via          => $input->{via} || 'web',
        },
        previous_hash  => undef,
        record_hash    => q{},
        schema_version => $SCHEMA_VERSION,
        target_id      => $dead_letter_id,
        target_type    => $AUDIT_TARGET,
    );

    return { status => 'replayed', replayed => \%replayed };
}

sub _refused ( $status, $error ) {
    return { status => $status, error => $error };
}

1;

__END__

=head1 NAME

GPForum::Service::Outbox::DeadLetterReplay - Put a dead letter's work back in the queue.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $outcome = $replay->replay(
        {
            actor_user_id  => $admin_id,
            dead_letter_id => $dead_letter_id,
            via            => 'web',
        }
    );
    # { status => 'replayed', replayed => { outbox_id => ..., ... } }

=head1 DESCRIPTION

ADR 0056 requires that an operator can review and replay dead letters. A
replay enqueues a new outbox message for the same event, job and payload,
with a fresh retry budget. The cancelled message and the dead letter are left
as they are, as the runbook requires (F<docs/ops/dead-letters.md>), and the
audit log records the replay with its actor.

=head1 SUBROUTINES/METHODS

=head2 replay

Returns C<{ status =E<gt> 'replayed', replayed =E<gt> {...} }>, or a refusal:
C<not_found> when there is no such dead letter, C<conflict> when it was
already replayed, does not name its event, or is not an outbox dead letter.

=head2 replay_key

The idempotency key of the message that replays a given dead letter.

=head1 DIAGNOSTICS

Dies when the database does.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::EventRecorder>, L<GPForum::Infrastructure::Id>,
L<GPForum::Infrastructure::OutboxMessageBuilder>, L<GPForum::Service::Clock>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
