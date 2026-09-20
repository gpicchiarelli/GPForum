package GPForum::Service::Community::ReputationLedger;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Clock;
use GPForum::Service::Id;

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
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub record_event {
    my ( $self, $input ) = @_;

    my $missing = $self->_missing_source($input);
    if ($missing) {
        return $missing;
    }

    my $existing = $self->_existing_event($input);
    if ($existing) {
        return $self->_complete_existing_event( $existing, $input );
    }

    return $self->_insert_or_reuse($input);
}

sub _missing_source {
    my ( $self, $input ) = @_;

    if ( _has_source($input) ) {
        return;
    }

    return {
        ok       => 1,
        reason   => 'missing_source',
        skipped  => 1,
        snapshot => $self->_current_snapshot( $input->{user_id} ),
    };
}

sub _insert_or_reuse {
    my ( $self, $input ) = @_;

    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_event($input); },
      );
    if ($created) {
        return $created;
    }

    return $self->_reuse_after_conflict( $input, $error );
}

sub _reuse_after_conflict {
    my ( $self, $input, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_event_after_unique( $input, $error );
}

sub _event_after_unique {
    my ( $self, $input, $error ) = @_;

    if ( _event_id_conflict($error) ) {
        return $self->_event_after_id_conflict($input);
    }
    if ( _event_source_conflict($error) ) {
        return $self->_reuse_event_row( $input, $error );
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _event_after_id_conflict {
    my ( $self, $input ) = @_;

    my $existing = $self->_existing_event($input);
    if ($existing) {
        return $self->_complete_existing_event( $existing, $input );
    }

    return $self->_retry_event_id($input);
}

sub _retry_event_id {
    my ( $self, $input ) = @_;

    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_insert_event($input); },
      );
    if ($created) {
        return $created;
    }

    GPForum::Infrastructure::UniqueConflict->rethrow($error);
    return;
}

sub _reuse_event_row {
    my ( $self, $input, $error ) = @_;

    my $existing = $self->_existing_event($input);
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_complete_existing_event( $existing, $input );
}

sub _event_id_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $ID_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _event_source_conflict {
    my ($error) = @_;

    if ( !defined $error || !length $error ) {
        return 0;
    }

    return index( $error, $SOURCE_CONSTRAINT ) >= 0 ? 1 : 0;
}

sub _insert_event {
    my ( $self, $input ) = @_;

    my $created_at = $self->clock->now_iso8601;
    my $event      = _event_row( $input, $created_at, $self->id_service->uuid );
    $self->schema->resultset('ReputationEvent')->create($event);
    my $snapshot = $self->_persist_snapshot( $input, $created_at );
    $self->_sync_user_trust($snapshot);

    return { ok => 1, event => $event, snapshot => $snapshot };
}

sub _persist_snapshot {
    my ( $self, $input, $created_at ) = @_;

    my $job      = { created_at => $created_at, input => $input };
    my $existing = $self->_snapshot_for( $input->{user_id} );
    if ($existing) {
        return $self->_apply_snapshot_delta( $existing, $job );
    }

    return $self->_insert_or_reuse_snapshot($job);
}

sub _insert_or_reuse_snapshot {
    my ( $self, $job ) = @_;

    my $row = $self->_snapshot_row( $job->{input}, $job->{created_at} );
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_snapshot($row); },
      );
    if ($created) {
        return $row;
    }

    return $self->_snapshot_after_conflict( $job, $error );
}

sub _snapshot_after_conflict {
    my ( $self, $job, $error ) = @_;

    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    my $existing = $self->_snapshot_for( $job->{input}{user_id} );
    if ( !$existing ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    return $self->_apply_snapshot_delta( $existing, $job );
}

sub _apply_snapshot_delta {
    my ( $self, $existing, $job ) = @_;

    my $row = _delta_snapshot( $existing, $job );
    if ( ref $existing eq 'HASH' ) {
        return _merge_snapshot( $existing, $row );
    }

    $existing->update($row);
    return $row;
}

sub _merge_snapshot {
    my ( $existing, $row ) = @_;

    for my $name ( keys %{$row} ) {
        $existing->{$name} = $row->{$name};
    }

    return $row;
}

sub _delta_snapshot {
    my ( $existing, $job ) = @_;

    my $score = ( _column( $existing, 'score' ) || 0 ) + $job->{input}{delta};

    return {
        calculated_at => $job->{created_at},
        score         => $score,
        trust_level   => trust_level_for_score($score),
        user_id       => $job->{input}{user_id},
        version       => $DEFAULT_VERSION,
    };
}

sub _create_snapshot {
    my ( $self, $row ) = @_;

    return $self->_snapshots->create($row);
}

sub _snapshot_for {
    my ( $self, $user_id ) = @_;

    return $self->_snapshots->find($user_id);
}

sub _snapshots {
    my ($self) = @_;

    return $self->schema->resultset('TrustScoreSnapshot');
}

sub _complete_existing_event {
    my ( $self, $event, $input ) = @_;

    if ( $self->_snapshot_for( $input->{user_id} ) ) {
        return $self->_replayed( $event, $input );
    }

    return $self->_finish_leftover_event( $event, $input );
}

sub _finish_leftover_event {
    my ( $self, $event, $input ) = @_;

    my $created_at = $event->{created_at} || $self->clock->now_iso8601;
    my $snapshot   = $self->_persist_snapshot( $input, $created_at );
    $self->_sync_user_trust($snapshot);

    return {
        event    => $event,
        ok       => 1,
        skipped  => 1,
        snapshot => $snapshot,
    };
}

sub _replayed {
    my ( $self, $event, $input ) = @_;

    return {
        event    => $event,
        ok       => 1,
        skipped  => 1,
        snapshot => $self->_current_snapshot( $input->{user_id} ),
    };
}

sub _current_snapshot {
    my ( $self, $user_id ) = @_;

    my $row = $self->schema->resultset('TrustScoreSnapshot')->find($user_id);
    return _empty_snapshot($user_id) if !$row;

    return {
        calculated_at => _column( $row, 'calculated_at' ),
        score         => _column( $row, 'score' ),
        trust_level   => _column( $row, 'trust_level' ),
        user_id       => _column( $row, 'user_id' ) || $user_id,
        version       => _column( $row, 'version' ) || $DEFAULT_VERSION,
    };
}

sub _empty_snapshot {
    my ($user_id) = @_;

    return {
        score       => 0,
        trust_level => $TRUST_LEVEL_ZERO,
        user_id     => $user_id,
        version     => $DEFAULT_VERSION,
    };
}

sub _event_row {
    my ( $input, $created_at, $event_id ) = @_;

    return {
        actor_id            => $input->{actor_id},
        created_at          => $created_at,
        delta               => $input->{delta},
        reason              => $input->{reason},
        reputation_event_id => $event_id,
        source_id           => $input->{source_id},
        source_type         => $input->{source_type},
        user_id             => $input->{user_id},
    };
}

sub _snapshot_row {
    my ( $self, $input, $created_at ) = @_;

    my $score = _declared_score($input) + $input->{delta};

    return {
        calculated_at => $created_at,
        score         => $score,
        trust_level   => trust_level_for_score($score),
        user_id       => $input->{user_id},
        version       => $DEFAULT_VERSION,
    };
}

sub _declared_score {
    my ($input) = @_;

    if ( defined $input->{current_score} ) {
        return $input->{current_score};
    }

    return 0;
}

sub _existing_event {
    my ( $self, $input ) = @_;

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

sub _sync_user_trust {
    my ( $self, $snapshot ) = @_;

    my $user = $self->schema->resultset('User')->find( $snapshot->{user_id} );
    if ( !$user ) {
        return;
    }
    if ( _same_trust( $user, $snapshot ) ) {
        return;
    }

    $user->update( { trust_level => $snapshot->{trust_level} } );

    return;
}

sub _same_trust {
    my ( $user, $snapshot ) = @_;

    my $held     = _column( $user, 'trust_level' );
    my $incoming = $snapshot->{trust_level};
    if ( !defined $held ) {
        return 0;
    }
    if ( !defined $incoming ) {
        return 0;
    }
    if ( $held == $incoming ) {
        return 1;
    }

    return 0;
}

sub _has_source {
    my ($input) = @_;

    if ( !_has_text( $input->{source_type} ) ) {
        return 0;
    }
    if ( !_has_text( $input->{source_id} ) ) {
        return 0;
    }

    return 1;
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value ? 1 : 0;
}

sub _column {
    my ( $row, $name ) = @_;

    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    return;
}

sub trust_level_for_score {
    my ($score) = @_;

    return $TRUST_LEVEL_FOUR  if $score >= $TRUST_LEVEL_FOUR_SCORE;
    return $TRUST_LEVEL_THREE if $score >= $TRUST_LEVEL_THREE_SCORE;
    return $TRUST_LEVEL_TWO   if $score >= $TRUST_LEVEL_TWO_SCORE;
    return $TRUST_LEVEL_ONE   if $score >= $TRUST_LEVEL_ONE_SCORE;

    return $TRUST_LEVEL_ZERO;
}

1;
