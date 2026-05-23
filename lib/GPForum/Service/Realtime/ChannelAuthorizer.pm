package GPForum::Service::Realtime::ChannelAuthorizer;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $THREAD_PREFIX       => 'thread';
const my $NOTIFICATION_PREFIX => 'notifications';

has permission_engine => undef;

sub authorize {
    my ( $self, $actor, $channel, $context ) = @_;

    my $parsed = parse_channel($channel);
    return { ok => 0, reason => 'unknown_channel' } if !$parsed;

    return $self->_authorize_notifications( $actor, $parsed )
      if $parsed->{type} eq $NOTIFICATION_PREFIX;

    return $self->_authorize_with_policy( $actor, $parsed, $context || {} );
}

sub parse_channel {
    my ($channel) = @_;

    my ( $type, $resource_id ) = split /:/msx, $channel, 2;
    return if !defined $type || !defined $resource_id || !length $resource_id;

    return {
        type        => $type,
        resource_id => $resource_id,
    };
}

sub _authorize_notifications {
    my ( $self, $actor, $parsed ) = @_;

    return { ok => 1, reason => 'own_notifications' }
      if $actor->{user_id} eq $parsed->{resource_id};

    return { ok => 0, reason => 'wrong_recipient' };
}

sub _authorize_with_policy {
    my ( $self, $actor, $parsed, $context ) = @_;

    return { ok => 1, reason => 'public_default' } if !$self->permission_engine;

    my $allowed = $self->permission_engine->can(
        $actor,
        'realtime.subscribe',
        {
            type => $parsed->{type},
            id   => $parsed->{resource_id},
        },
        $context
    );

    return { ok => 1, reason => 'policy_allowed' } if $allowed;

    return { ok => 0, reason => 'policy_denied' };
}

1;

