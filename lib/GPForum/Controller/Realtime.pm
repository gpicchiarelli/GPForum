package GPForum::Controller::Realtime;

use strict;
use warnings;

use Const::Fast;
use GPForum::Web::Access;
use GPForum::Web::RealtimeAccess;
use GPForum::Web::RealtimePayload;
use Mojo::Base 'Mojolicious::Controller';

our $VERSION = '0.001';

const my $HTTP_FORBIDDEN => 403;
const my $HTTP_PAYLOAD   => 413;
const my $HTTP_TOO_MANY  => 429;

has realtime_access => sub { return GPForum::Web::RealtimeAccess->new; };

sub stream {
    my ($self) = @_;

    my $denied = $self->_stream_denied;
    if ($denied) {
        return $denied;
    }

    return $self->_accept_stream;
}

sub _stream_denied {
    my ($self) = @_;

    if ( !$self->_origin_allowed ) {
        return $self->_origin_denied;
    }

    return $self->_stream_identity_denied;
}

sub _origin_allowed {
    my ($self) = @_;

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

sub _stream_identity_denied {
    my ($self) = @_;

    my $user_id = $self->_current_user_id;
    if ( !GPForum::Web::Access->new->has_text($user_id) ) {
        return $self->_handshake_text(
            $self->realtime_access->authentication_required );
    }

    return $self->_stream_limit_denied($user_id);
}

sub _stream_limit_denied {
    my ( $self, $user_id ) = @_;

    if ( !$self->_rate_limit( $user_id, $self->realtime_access->connect_action )
      )
    {
        return $self->_connect_rate_limited;
    }

    return;
}

sub _accept_stream {
    my ($self) = @_;

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

sub _handle_message {
    my ( $self, $input ) = @_;

    my $error = $self->_message_error($input);
    if ($error) {
        return $self->_send_error($error);
    }

    return $self->_subscribe($input);
}

sub _message_error {
    my ( $self, $input ) = @_;

    my $oversized = $self->_oversized_error( $input->{message} );
    if ($oversized) {
        return $oversized;
    }

    return $self->_subscribe_precheck($input);
}

sub _oversized_error {
    my ( $self, $message ) = @_;

    if ( !$self->realtime_access->payload_too_large($message) ) {
        return;
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

sub _subscribe_precheck {
    my ( $self, $input ) = @_;

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

    return;
}

sub _subscribe {
    my ( $self, $input ) = @_;

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

    return $self->send(
        {
            json => GPForum::Web::RealtimePayload->subscribed(
                channel => $result->{channel},
            ),
        }
    );
}

sub _subscription_denied {
    my ( $self, $input, $result ) = @_;

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

sub _send_connected {
    my ( $self, $connection_id ) = @_;

    return $self->send(
        {
            json => GPForum::Web::RealtimePayload->connected(
                connection_id => $connection_id,
                fallback      => $self->gp_realtime_hub->fallback_state,
            ),
        }
    );
}

sub _send_error {
    my ( $self, $reason ) = @_;

    return $self->send(
        {
            json => GPForum::Web::RealtimePayload->error( reason => $reason ),
        }
    );
}

sub _origin_denied {
    my ($self) = @_;

    return $self->_handshake_text( $self->realtime_access->origin_denied );
}

sub _connect_rate_limited {
    my ($self) = @_;

    return $self->_handshake_text(
        $self->realtime_access->too_many_connections );
}

sub _connection_quota_denied {
    my ($self) = @_;

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

sub _handshake_text {
    my ( $self, $payload ) = @_;

    return $self->render(
        text   => $payload->{text},
        status => $payload->{status},
    );
}

sub _rate_limit {
    my ( $self, $user_id, $action ) = @_;

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

sub _current_user_id {
    my ($self) = @_;

    return GPForum::Web::Access->new->user_id($self);
}

sub _telemetry {
    my ( $self, $event_type, $metadata ) = @_;

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

Websocket state is process-local. Polling remains the authoritative fallback.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut

