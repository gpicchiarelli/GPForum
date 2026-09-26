# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Realtime::ChannelAuthorizer;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

our $VERSION = '0.001';

const my $THREAD_PREFIX       => 'thread';
const my $NOTIFICATION_PREFIX => 'notifications';

# No presence family: nothing published to it, so any user could subscribe to
# presence:<anything> and receive nothing. A cluster-wide presence would need
# a shared registry, which ADR 0067 rules out; a node-local one would show
# each viewer a different forum.
const my %SUPPORTED_CHANNELS => map { $_ => 1 }
  qw(thread notifications moderation admin feed);

has permission_engine => undef;

sub authorize ( $self, $actor, $channel, $context ) {
    my $parsed = parse_channel($channel);
    return { ok => 0, reason => 'malformed_channel' } if !$parsed;
    return { ok => 0, reason => 'unknown_channel' }
      if !exists $SUPPORTED_CHANNELS{ $parsed->{type} };
    return { ok => 0, reason => 'authentication_required' }
      if !_user_id($actor);

    return $self->_authorize_notifications( $actor, $parsed )
      if $parsed->{type} eq $NOTIFICATION_PREFIX;

    return $self->_authorize_with_policy( $actor, $parsed, $context || {} );
}

sub parse_channel ($channel) {
    my $undefined;
    return $undefined if !defined $channel || ref $channel;
    return $undefined
      if $channel !~ /\A ([a-z][a-z0-9_]*) [:] ([A-Za-z0-9_.-]+) \z/msx;

    my ( $type, $resource_id ) = ( $1, $2 );

    return {
        type        => $type,
        resource_id => $resource_id,
    };
}

sub _authorize_notifications ( $self, $actor, $parsed ) {
    my $user_id = _user_id($actor);
    return { ok => 1, reason => 'own_notifications' }
      if $user_id eq $parsed->{resource_id};

    return { ok => 0, reason => 'wrong_recipient' };
}

sub _authorize_with_policy ( $self, $actor, $parsed, $context ) {
    return { ok => 0, reason => 'forbidden' } if !$self->permission_engine;

    my $decision = $self->permission_engine->permits(
        $actor,
        'realtime.subscribe',
        {
            type => $parsed->{type},
            id   => $parsed->{resource_id},
        },
        $context
    );

    return _normalize_policy_decision($decision);
}

sub _normalize_policy_decision ($decision) {
    if ( ref $decision eq 'HASH' ) {
        return {
            ok     => $decision->{ok} ? 1 : 0,
            reason => $decision->{reason}
              || ( $decision->{ok} ? 'policy_allowed' : 'forbidden' ),
        };
    }

    return { ok => 1, reason => 'policy_allowed' } if $decision;

    return { ok => 0, reason => 'forbidden' };
}

sub _user_id ($actor) {
    my $undefined;
    return $undefined        if !defined $actor;
    return $actor->{user_id} if ref $actor eq 'HASH';

    return $actor;
}

1;
