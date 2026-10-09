# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Realtime;

use Const::Fast;
use GPForum::Web::Access;
use GPForum::Web::RealtimeAccess;
use GPForum::Web::RealtimePayload;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use v5.40;

our $VERSION = '0.001';

const my $HTTP_FORBIDDEN => 403;
const my $HTTP_PAYLOAD   => 413;
const my $HTTP_TOO_MANY  => 429;

has realtime_access => sub { return GPForum::Web::RealtimeAccess->new; };

sub stream ($self) {
    my $access = $self->realtime_access;
    if ( !$access->origin_allowed($self) ) {
        $self->_telemetry(
            'realtime_origin_denied',
            {
                reason => 'origin_denied',
                status => $HTTP_FORBIDDEN,
            },
        );
        return $self->_handshake_text( $access->origin_denied );
    }

    my $user_id = $self->_current_user_id;
    if ( !GPForum::Web::Access->new->has_text($user_id) ) {
        return $self->_handshake_text( $access->authentication_required );
    }
    if ( !$self->_rate_limit( $user_id, $access->connect_action ) ) {
        return $self->_handshake_text( $access->too_many_connections );
    }

    return $self->_accept_stream($user_id);
}

sub _accept_stream ( $self, $user_id ) {
    my $connection_id = $self->gp_id->uuid;
    my $actor         = { user_id => $user_id };
    my $registered =
      $self->gp_realtime_hub->register_connection( $connection_id, $actor,
        $self );
    if ( !$registered ) {
        $self->_telemetry(
            'realtime_connection_denied',
            {
                reason => 'connection_quota_exceeded',
                status => $HTTP_TOO_MANY,
            },
        );
        return $self->_handshake_text(
            $self->realtime_access->too_many_connections );
    }

    $self->send(
        {
            json => GPForum::Web::RealtimePayload->connected(
                connection_id => $connection_id,
                fallback      => $self->gp_realtime_hub->fallback_state,
            ),
        }
    );
    $self->on(
        json => sub ( $controller, $message, @ ) {
            $controller->_handle_message(
                {
                    actor         => $actor,
                    connection_id => $connection_id,
                    message       => $message,
                }
            );
        }
    );
    $self->on(
        finish => sub ( $controller, @ ) {
            $controller->gp_realtime_hub->disconnect($connection_id);
        }
    );

    return;
}

sub _handle_message ( $self, $input ) {
    my $access  = $self->realtime_access;
    my $message = $input->{message};
    if ( $access->payload_too_large($message) ) {
        $self->_telemetry(
            'realtime_payload_rejected',
            {
                payload_size => $access->payload_bytes($message),
                reason       => 'payload_too_large',
                status       => $HTTP_PAYLOAD,
            },
        );
        return $self->_send_error('payload_too_large');
    }
    if ( !$access->is_subscribe($message) ) {
        return $self->_send_error('unknown_message');
    }
    if (
        !$self->_rate_limit(
            $input->{actor}{user_id},
            $access->subscribe_action
        )
      )
    {
        return $self->_send_error('rate_limited');
    }

    return $self->_subscribe($input);
}

sub _subscribe ( $self, $input ) {
    my $result = $self->gp_realtime_hub->subscribe(
        {
            actor         => $input->{actor},
            channel       => $input->{message}{channel},
            connection_id => $input->{connection_id},
            context       => { transport => 'websocket' },
        }
    );
    if ( !$result->{ok} ) {
        $self->_telemetry(
            'realtime_subscription_denied',
            {
                channel_type => $self->realtime_access->channel_type(
                    $input->{message}{channel}
                ),
                reason => $result->{reason},
                status => $HTTP_FORBIDDEN,
            },
        );
        return $self->_send_error( $result->{reason} );
    }

    $self->send(
        {
            json => GPForum::Web::RealtimePayload->subscribed(
                channel => $result->{channel},
            ),
        }
    );

    # There is no replay log (ADR 0110). A subscriber that has just connected,
    # to this node or after losing another, gets its current count at once
    # instead of waiting for the next change to correct it.
    if ( $self->realtime_access->channel_type( $result->{channel} ) eq
        'notifications' )
    {
        $self->gp_realtime_hub->send_badge_snapshot( $input->{connection_id} );
    }

    return $self;
}

sub _send_error ( $self, $reason ) {
    return $self->send(
        {
            json => GPForum::Web::RealtimePayload->error( reason => $reason ),
        }
    );
}

sub _handshake_text ( $self, $payload ) {
    return $self->render(
        text   => $payload->{text},
        status => $payload->{status},
    );
}

sub _rate_limit ( $self, $user_id, $action ) {
    my $decision = $self->gp_rate_limiter->check(
        $self->realtime_access->write_rate_input(
            {
                action   => $action,
                actor_id => $user_id,
            }
        )
    );

    return $decision->{ok} ? 1 : 0;
}

sub _current_user_id ($self) {
    return GPForum::Web::Access->new->user_id($self);
}

sub _telemetry ( $self, $event_type, $metadata ) {
    return $self->gp_security_telemetry->record( $event_type, $metadata );
}

1;
__END__

=head1 NAME

GPForum::Controller::Realtime - Authenticated websocket stream.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->websocket('/realtime')->to('Realtime#stream');

=head1 DESCRIPTION

Upgrades an authenticated same-origin session to a process-local websocket.
Handshake origin, payload size, subscribe-message shape, connect/subscribe
rate-limit hashes, and plaintext handshake texts are decided by
L<GPForum::Web::RealtimeAccess>. The rate limiter, hub registration,
telemetry, and frames stay here.

Any node accepts any client: nothing ties a user to a process. A subscription
to C<notifications:E<lt>user_idE<gt>> is answered with C<subscribed> and then
a C<notification.badge> snapshot of the current unread count. Other channels
carry id-only hints, so a client that (re)connects refetches their canonical
state from the C<fallback> endpoints and then applies hints.

=head1 SUBROUTINES/METHODS

=head2 stream

Accepts the websocket after origin, authentication, rate-limit, and quota
checks.

=head1 DIAGNOSTICS

Missing authentication renders C<401>. Foreign origins render C<403>. Connect
rate limits and quotas render C<429>. Subscribe failures send websocket error
frames without closing the canonical write path.

=head1 CONFIGURATION AND ENVIRONMENT

Uses realtime hub, rate limiter, and security telemetry helpers registered
during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Web::Access>, L<GPForum::Web::RealtimeAccess>, and
L<GPForum::Web::RealtimePayload>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Websocket state is process-local and there is no server-side replay: events
sent while a client was disconnected are not resent. Polling and the refetch
on reconnect remain the authoritative fallback.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut

