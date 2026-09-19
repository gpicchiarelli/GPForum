package GPForum::Service::Community::ReputationLedger;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

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

has clock      => sub { return GPForum::Service::Clock->new; };
has id_service => sub { return GPForum::Service::Id->new; };
has schema     => undef;

sub record_event {
    my ( $self, $input ) = @_;

    my $existing = $self->_existing_event($input);
    return $self->_replayed( $existing, $input ) if $existing;

    return $self->_insert_event($input);
}

sub _insert_event {
    my ( $self, $input ) = @_;

    my $created_at = $self->clock->now_iso8601;
    my $event      = _event_row( $input, $created_at, $self->id_service->uuid );
    my $snapshot   = $self->_snapshot_row( $input, $created_at );

    $self->schema->resultset('ReputationEvent')->create($event);
    $self->schema->resultset('TrustScoreSnapshot')->update_or_create($snapshot);
    $self->_sync_user_trust($snapshot);

    return { ok => 1, event => $event, snapshot => $snapshot };
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

    my $score = $self->_current_score($input) + $input->{delta};

    return {
        calculated_at => $created_at,
        score         => $score,
        trust_level   => trust_level_for_score($score),
        user_id       => $input->{user_id},
        version       => $DEFAULT_VERSION,
    };
}

sub _current_score {
    my ( $self, $input ) = @_;

    return $input->{current_score} if defined $input->{current_score};

    return $self->_snapshot_score( $input->{user_id} );
}

sub _snapshot_score {
    my ( $self, $user_id ) = @_;

    my $row = $self->schema->resultset('TrustScoreSnapshot')->find($user_id);
    return 0 if !$row;

    return $row->get_column('score') || 0;
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
    return if !$user;

    $user->update( { trust_level => $snapshot->{trust_level} } );

    return;
}

sub _has_source {
    my ($input) = @_;

    return defined $input->{source_type}
      && defined $input->{source_id} ? 1 : 0;
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
