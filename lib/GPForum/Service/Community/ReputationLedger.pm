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

    my $created_at = $self->clock->now_iso8601;
    my $event      = {
        reputation_event_id => $self->id_service->uuid,
        user_id             => $input->{user_id},
        actor_id            => $input->{actor_id},
        source_type         => $input->{source_type},
        source_id           => $input->{source_id},
        delta               => $input->{delta},
        reason              => $input->{reason},
        created_at          => $created_at,
    };
    my $score    = ( $input->{current_score} || 0 ) + $input->{delta};
    my $snapshot = {
        user_id       => $input->{user_id},
        score         => $score,
        trust_level   => trust_level_for_score($score),
        calculated_at => $created_at,
        version       => $DEFAULT_VERSION,
    };

    $self->schema->resultset('ReputationEvent')->create($event);
    $self->schema->resultset('TrustScoreSnapshot')->update_or_create($snapshot);

    return { ok => 1, event => $event, snapshot => $snapshot };
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
