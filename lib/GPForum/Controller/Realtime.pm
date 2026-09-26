# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Realtime;

use strict;
use warnings;

use Const::Fast;
use GPForum::Web::Access;
use GPForum::Web::RealtimeAccess;
use GPForum::Web::RealtimePayload;
use Mojo::Base 'Mojolicious::Controller', -signatures;

our $VERSION = '0.001';

const my $HTTP_FORBIDDEN => 403;
const my $HTTP_PAYLOAD   => 413;
const my $HTTP_TOO_MANY  => 429;

has realtime_access => sub { return GPForum::Web::RealtimeAccess->new; };

sub stream ($self) {
    my $denied = $self->_stream_denied;
    if ($denied) {
        return $denied;
    }

    return $self->_accept_stream;
}

sub _stream_denied ($self) {
    if ( !$self->_origin_allowed ) {
        return $self->_origin_denied;
    }

    return $self->_stream_identity_denied;
}

sub _origin_allowed ($self) {
    if ( $self->realtime_access->origin_allowed($self) ) {
        return 1;
    }

    $self->_telemetry(
        'realtime_origin_denied',
        {
            reason => 'origin_denied',
            status => $HTTP_FORBIDDEN,
        },
    );

    return 0;
}

sub _stream_identity_denied ($self) {
    my $user_id = $self->_current_user_id;
    if ( !GPForum::Web::Access->new->has_text($user_id) ) {
        return $self->_handshake_text(
            $self->realtime_access->authentication_required );
    }

    return $self->_stream_limit_denied($user_id);
}

sub _stream_limit_denied ( $self, $user_id ) {
    if ( !$self->_rate_limit( $user_id, $self->realtime_access->connect_action )
      )
    {
        return $self->_connect_rate_limited;
    }

    my $undefined;
    return $undefined;
}

sub _accept_stream ($self) {
    my $connection_id = $self->gp_id->uuid;
    my $actor         = { user_id => $self->_current_user_id };
    my $registered =
      $self->gp_realtime_hub->register_connection( $connection_id, $actor,
        $self );
    if ( !$registered ) {
        return $self->_connection_quota_denied;
    }

    return $self->_bind_stream( $connection_id, $actor );
}

sub _bind_stream {
    my ( $self, $connection_id, $actor ) = @_;

    $self->_send_connected($connection_id);
    $self->on(
        json => sub {
            my ( $controller, $message ) = @_;
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
        finish => sub {
            my ($controller) = @_;
            $controller->gp_realtime_hub->disconnect($connection_id);
        }
    );

    return;
}

sub _handle_message ( $self, $input ) {
    my $error = $self->_message_error($input);
    if ($error) {
        return $self->_send_error($error);
    }

    return $self->_subscribe($input);
}

sub _message_error ( $self, $input ) {
    my $oversized = $self->_oversized_error( $input->{message} );
    if ($oversized) {
        return $oversized;
    }

    return $self->_subscribe_precheck($input);
}

sub _oversized_error ( $self, $message ) {
    if ( !$self->realtime_access->payload_too_large($message) ) {
        my $undefined;
        return $undefined;
    }

    $self->_telemetry(
        'realtime_payload_rejected',
        {
            payload_size => $self->realtime_access->payload_bytes($message),
            reason       => 'payload_too_large',
            status       => $HTTP_PAYLOAD,
        },
    );

    return 'payload_too_large';
}

sub _subscribe_precheck ( $self, $input ) {
    if ( !$self->realtime_access->is_subscribe( $input->{message} ) ) {
        return 'unknown_message';
    }
    if (
        !$self->_rate_limit(
            $input->{actor}{user_id},
            $self->realtime_access->subscribe_action
        )
      )
    {
        return 'rate_limited';
    }

    my $undefined;
    return $undefined;
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
        return $self->_subscription_denied( $input, $result );
    }

    $self->send(
        {
            json => GPForum::Web::RealtimePayload->subscribed(
                channel => $result->{channel},
            ),
        }
    );

    return $self->_send_badge_snapshot( $input->{connection_id},
        $result->{channel} );
}

# There is no replay log (ADR 0110). A subscriber that has just connected,
# to this node or after losing another, gets its current count at once
# instead of waiting for the next change to correct it.
sub _send_badge_snapshot ( $self, $connection_id, $channel ) {
    if ( $self->realtime_access->channel_type($channel) ne 'notifications' ) {
        return $self;
    }

    $self->gp_realtime_hub->send_badge_snapshot($connection_id);

    return $self;
}

sub _subscription_denied ( $self, $input, $result ) {
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

sub _send_connected ( $self, $connection_id ) {
    return $self->send(
        {
            json => GPForum::Web::RealtimePayload->connected(
                connection_id => $connection_id,
                fallback      => $self->gp_realtime_hub->fallback_state,
            ),
        }
    );
}

sub _send_error ( $self, $reason ) {
    return $self->send(
        {
            json => GPForum::Web::RealtimePayload->error( reason => $reason ),
        }
    );
}

sub _origin_denied ($self) {
    return $self->_handshake_text( $self->realtime_access->origin_denied );
}

sub _connect_rate_limited ($self) {
    return $self->_handshake_text(
        $self->realtime_access->too_many_connections );
}

sub _connection_quota_denied ($self) {
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

