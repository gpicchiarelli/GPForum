# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Community::ReputationLedger;

use Const::Fast;
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;
use GPForum::X::Conflict;

our $VERSION = '0.001';

const my $TRUST_LEVEL_ONE_SCORE   => 10;
const my $TRUST_LEVEL_TWO_SCORE   => 50;
const my $TRUST_LEVEL_THREE_SCORE => 150;
const my $TRUST_LEVEL_FOUR_SCORE  => 500;
const my $TRUST_LEVEL_ZERO        => 0;
const my $TRUST_LEVEL_ONE         => 1;
const my $TRUST_LEVEL_TWO         => 2;
const my $TRUST_LEVEL_THREE       => 3;
const my $TRUST_LEVEL_FOUR        => 4;
const my $DEFAULT_VERSION         => 1;
const my $ID_CONSTRAINT           => 'reputation_events_pkey';
const my $SOURCE_CONSTRAINT       => 'idx_reputation_events_source_unique';

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Infrastructure::Id->new; };
__PACKAGE__->requires(qw(schema));

sub record_event ( $self, $input ) {
    return $self->schema->txn_do(
        sub {
            return $self->_record_event($input);
        }
    );
}

# reputation_events, trust_score_snapshots and the denormalized user trust
# level are written together. Without one transaction a failed snapshot write
# left the ledger crediting a delta the score never received.
#
# An event without a source is skipped. The event already stored for its
# source -- before, or by a concurrent request -- is replayed; a minted id
# already stored with no such event is minted once more.
sub _record_event ( $self, $input ) {
    if ( !_has_source($input) ) {
        return {
            ok       => 1,
            reason   => 'missing_source',
            skipped  => 1,
            snapshot => $self->_current_snapshot( $input->{user_id} ),
        };
    }

    my $existing = $self->_existing_event($input);
    if ($existing) {
        return $self->_complete_existing_event( $existing, $input );
    }

    my $insert = sub { return $self->_insert_event($input); };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $insert );
    if ($created) {
        return $created;
    }

    my $conflict = GPForum::X::Conflict->caught($error);
    my $id_taken = $conflict && $conflict->on($ID_CONSTRAINT);
    if ( $id_taken || ( $conflict && $conflict->on($SOURCE_CONSTRAINT) ) ) {
        $existing = $self->_existing_event($input);
        if ($existing) {
            return $self->_complete_existing_event( $existing, $input );
        }
    }
    if ( !$id_taken ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        $insert );
    if ($created) {
        return $created;
    }
    GPForum::Infrastructure::UniqueConflict->rethrow($error);
}

sub _insert_event ( $self, $input ) {
    my $created_at = $self->clock->now_iso8601;
    my $event      = {
        actor_id            => $input->{actor_id},
        created_at          => $created_at,
        delta               => $input->{delta},
        reason              => $input->{reason},
        reputation_event_id => $self->id_service->uuid,
        source_id           => $input->{source_id},
        source_type         => $input->{source_type},
        user_id             => $input->{user_id},
    };
    $self->schema->resultset('ReputationEvent')->create($event);
    my $snapshot = $self->_persist_snapshot( $input, $created_at );
    $self->_sync_user_trust($snapshot);

    return { ok => 1, event => $event, snapshot => $snapshot };
}

# The member's snapshot gets the delta; a member without one gets a first
# snapshot from the score the caller declares. The snapshot is keyed by its
# member alone: a conflict is another request's first snapshot, which this
# delta is applied to.
sub _persist_snapshot ( $self, $input, $created_at ) {
    my $job      = { created_at => $created_at, input => $input };
    my $existing = $self->_snapshot_for( $input->{user_id} );
    if ($existing) {
        return $self->_apply_snapshot_delta( $existing, $job );
    }

    my $score = ( $input->{current_score} // 0 ) + $input->{delta};
    my $row   = {
        calculated_at => $created_at,
        score         => $score,
        trust_level   => trust_level_for_score($score),
        user_id       => $input->{user_id},
        version       => $DEFAULT_VERSION,
    };
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_snapshots->create($row); } );
    if ($created) {
        return $row;
    }

    $existing =
      GPForum::X::Conflict->caught($error)
      ? $self->_snapshot_for( $input->{user_id} )
      : undef;
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_apply_snapshot_delta( $existing, $job );
}

sub _apply_snapshot_delta ( $self, $existing, $job ) {
    my $score = ( _column( $existing, 'score' ) || 0 ) + $job->{input}{delta};
    my $row   = {
        calculated_at => $job->{created_at},
        score         => $score,
        trust_level   => trust_level_for_score($score),
        user_id       => $job->{input}{user_id},
        version       => $DEFAULT_VERSION,
    };
    if ( ref $existing eq 'HASH' ) {
        @{$existing}{ keys %{$row} } = values %{$row};
        return $row;
    }

    $existing->update($row);
    return $row;
}

# The snapshot is read, incremented and written back, so the row has to be
# locked for the rest of the transaction or a concurrent delta is lost.
sub _snapshot_for ( $self, $user_id ) {
    return $self->_snapshots->find( $user_id, { for => 'update' } );
}

sub _snapshots ($self) {
    return $self->schema->resultset('TrustScoreSnapshot');
}

# An earlier attempt may have stored the event without its snapshot.
sub _complete_existing_event ( $self, $event, $input ) {
    my $snapshot;
    if ( $self->_snapshot_for( $input->{user_id} ) ) {
        $snapshot = $self->_current_snapshot( $input->{user_id} );
    }
    else {
        $snapshot = $self->_persist_snapshot( $input,
            $event->{created_at} || $self->clock->now_iso8601 );
        $self->_sync_user_trust($snapshot);
    }

    return {
        event    => $event,
        ok       => 1,
        skipped  => 1,
        snapshot => $snapshot,
    };
}

sub _current_snapshot ( $self, $user_id ) {
    my $row = $self->schema->resultset('TrustScoreSnapshot')->find($user_id);
    if ( !$row ) {
        return {
            score       => 0,
            trust_level => $TRUST_LEVEL_ZERO,
            user_id     => $user_id,
            version     => $DEFAULT_VERSION,
        };
    }

    return {
        calculated_at => _column( $row, 'calculated_at' ),
        score         => _column( $row, 'score' ),
        trust_level   => _column( $row, 'trust_level' ),
        user_id       => _column( $row, 'user_id' ) || $user_id,
        version       => _column( $row, 'version' ) || $DEFAULT_VERSION,
    };
}

sub _existing_event ( $self, $input ) {
    return if !_has_source($input);

    my $row = $self->schema->resultset('ReputationEvent')->find(
        {
            source_id   => $input->{source_id},
            source_type => $input->{source_type},
            user_id     => $input->{user_id},
        }
    );
    return if !$row;

    return {
        actor_id            => _column( $row, 'actor_id' ),
        created_at          => _column( $row, 'created_at' ),
        delta               => _column( $row, 'delta' ),
        reason              => _column( $row, 'reason' ),
        reputation_event_id => _column( $row, 'reputation_event_id' ),
        source_id           => _column( $row, 'source_id' ),
        source_type         => _column( $row, 'source_type' ),
        user_id             => _column( $row, 'user_id' ),
    };
}

sub _sync_user_trust ( $self, $snapshot ) {
    my $user = $self->schema->resultset('User')->find( $snapshot->{user_id} );
    if ( !$user ) {
        return;
    }

    my $held     = _column( $user, 'trust_level' );
    my $incoming = $snapshot->{trust_level};
    if ( defined $held && defined $incoming && $held == $incoming ) {
        return;
    }

    $user->update( { trust_level => $snapshot->{trust_level} } );

    return;
}

sub _has_source ($input) {
    if ( !_has_text( $input->{source_type} ) ) {
        return 0;
    }
    if ( !_has_text( $input->{source_id} ) ) {
        return 0;
    }

    return 1;
}

sub _has_text ($value) {
    return defined $value && length $value ? 1 : 0;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

sub trust_level_for_score ($score) {
    return $TRUST_LEVEL_FOUR  if $score >= $TRUST_LEVEL_FOUR_SCORE;
    return $TRUST_LEVEL_THREE if $score >= $TRUST_LEVEL_THREE_SCORE;
    return $TRUST_LEVEL_TWO   if $score >= $TRUST_LEVEL_TWO_SCORE;
    return $TRUST_LEVEL_ONE   if $score >= $TRUST_LEVEL_ONE_SCORE;

    return $TRUST_LEVEL_ZERO;
}

1;

__END__

=head1 NAME

GPForum::Service::Community::ReputationLedger - Reputation deltas, the running trust score and the trust level it gives.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $ledger =
      GPForum::Service::Community::ReputationLedger->new( schema => $schema );

    my $result = $ledger->record_event(
        {
            actor_id    => $actor_id,
            delta       => 1,
            reason      => 'post_created',
            source_id   => $post_id,
            source_type => 'post',
            user_id     => $author_id,
        }
    );
    # { ok => 1, event => {...}, snapshot => { score, trust_level, ... } }

    my $level =
      GPForum::Service::Community::ReputationLedger::trust_level_for_score(60);
    # 2

=head1 DESCRIPTION

Each reputation change is a C<reputation_events> row identified by its
source (C<source_type>, C<source_id> and C<user_id>), so a replayed domain
event credits nothing twice. The member's C<trust_score_snapshots> row
holds the running score; it is read with C<FOR UPDATE> and incremented, so
a concurrent delta is not lost, and the trust level it gives is copied to
the user row. The event, the snapshot and the user's trust level are
written in one transaction: written apart, a failed snapshot write left the
ledger crediting a delta the score never received.

The trust levels are 0 below 10 points, 1 from 10, 2 from 50, 3 from 150
and 4 from 500. A member's first snapshot starts from C<current_score> when
the input gives one, 0 otherwise. An event already recorded whose member has
no snapshot, left by an interrupted write, has its snapshot written now.

=head1 SUBROUTINES/METHODS

=head2 record_event

Takes a hash reference with C<user_id>, C<delta>, C<source_type>,
C<source_id>, C<actor_id>, C<reason> and an optional C<current_score>. In a
transaction, returns C<< { ok => 1, event, snapshot } >> for a new event;
C<< { ok => 1, skipped => 1, event, snapshot } >> when the source was
already recorded, with the current snapshot or the one just written for a
leftover event; and C<< { ok => 1, skipped => 1, reason => 'missing_source',
snapshot } >>, recording nothing, when C<source_type> or C<source_id> is
empty. The snapshot is C<< { user_id, score, trust_level, calculated_at,
version } >>; for a member without one it has score and level 0 and no
C<calculated_at>.

=head2 trust_level_for_score

A function, not a method. Takes a score and returns the trust level it
gives, from 0 to 4.

=head1 DIAGNOSTICS

An insert error other than a collision on the event id or on the event's
source, or a collision whose winning row cannot be found, is rethrown with
C<croak>; other database errors propagate. Either rolls the transaction
back.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::Row>, L<GPForum::Infrastructure::UniqueConflict>,
L<GPForum::X::Conflict>, L<GPForum::Infrastructure::Id>,
L<GPForum::Service::Clock>.

Extends L<GPForum::Base>: built without C<schema> it throws
L<GPForum::X::Argument>.

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
