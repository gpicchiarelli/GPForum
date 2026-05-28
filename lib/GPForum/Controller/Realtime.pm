package GPForum::Controller::Realtime;

use strict;
use warnings;

use Const::Fast;
use GPForum::Web::RealtimePayload;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(encode_json);
use Mojo::URL;

our $VERSION = '0.001';

const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_TOO_MANY     => 429;
const my $CONNECT_LIMIT     => 30;
const my $SUBSCRIBE_LIMIT   => 120;
const my $WINDOW_SECONDS    => 60;
const my $MAX_MESSAGE_BYTES => 2048;

sub stream {
    my ($self) = @_;

    return $self->_origin_denied if !$self->_valid_origin;

    my $user_id = $self->session('user_id');
    return $self->render(
        text   => 'Authentication required',
        status => $HTTP_UNAUTHORIZED,
    ) if !defined $user_id || !length $user_id;

    return $self->_connect_rate_limited
      if !$self->_rate_limit( $user_id, 'realtime.connect', $CONNECT_LIMIT );

    my $connection_id = $self->gp_id->uuid;
    my $actor         = { user_id => $user_id };

    my $registered =
      $self->gp_realtime_hub->register_connection( $connection_id, $actor,
        $self );
    return $self->_connection_quota_denied if !$registered;

    $self->_send_connected($connection_id);

    $self->on(
        json => sub {
            my ( $controller, $message ) = @_;
            $controller->_handle_message( $connection_id, $actor, $message );
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
    my ( $self, $connection_id, $actor, $message ) = @_;

    return $self->_send_error('payload_too_large')
      if $self->_message_too_large($message);

    return $self->_send_error('unknown_message')
      if !$message || ( $message->{type} || q{} ) ne 'subscribe';
    return $self->_send_error('rate_limited')
      if !$self->_rate_limit( $actor->{user_id}, 'realtime.subscribe',
        $SUBSCRIBE_LIMIT );

    my $result = $self->gp_realtime_hub->subscribe(
        {
            connection_id => $connection_id,
            actor         => $actor,
            channel       => $message->{channel},
            context       => { transport => 'websocket' },
        }
    );

    if ( !$result->{ok} ) {
        $self->_telemetry(
            'realtime_subscription_denied',
            {
                reason       => $result->{reason},
                channel_type => _channel_type( $message->{channel} ),
                status       => 403,
            },
        );
        return $self->_send_error( $result->{reason} );
    }

    return $self->send(
        {
            json => GPForum::Web::RealtimePayload->subscribed(
                channel => $result->{channel},
            ),
        }
    );
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

sub _valid_origin {
    my ($self) = @_;

    my $origin = $self->req->headers->header('Origin');
    return 1 if !defined $origin || !length $origin;

    return 1 if $origin eq $self->_request_origin;
    return 1 if $origin eq $self->_configured_origin;

    $self->_telemetry(
        'realtime_origin_denied',
        {
            reason => 'origin_denied',
            status => 403,
        },
    );

    return 0;
}

sub _request_origin {
    my ($self) = @_;

    my $base   = $self->req->url->base;
    my $scheme = $base->scheme || 'http';
    my $host   = $self->req->headers->host || $base->host || q{};

    return join q{://}, $scheme, $host;
}

sub _configured_origin {
    my ($self) = @_;

    my $url  = Mojo::URL->new( $self->gp_config->public_base_url );
    my $host = $url->host || q{};
    $host .= q{:} . $url->port if defined $url->port;

    return join q{://}, $url->scheme || 'http', $host;
}

sub _origin_denied {
    my ($self) = @_;

    return $self->render( text => 'Origin denied', status => 403 );
}

sub _connect_rate_limited {
    my ($self) = @_;

    return $self->render(
        text   => 'Too many realtime connections',
        status => $HTTP_TOO_MANY,
    );
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

    return $self->render(
        text   => 'Too many realtime connections',
        status => $HTTP_TOO_MANY,
    );
}

sub _rate_limit {
    my ( $self, $user_id, $action, $limit ) = @_;

    my $decision = $self->gp_rate_limiter->check(
        {
            scope          => 'user',
            actor_id       => $user_id,
            action         => $action,
            limit          => $limit,
            window_seconds => $WINDOW_SECONDS,
        }
    );

    return $decision->{ok} ? 1 : 0;
}

sub _message_too_large {
    my ( $self, $message ) = @_;

    my $json = eval { return encode_json( $message || {} ); };
    return 0 if !defined $json;

    if ( length($json) <= $MAX_MESSAGE_BYTES ) {
        return 0;
    }

    $self->_telemetry(
        'realtime_payload_rejected',
        {
            reason       => 'payload_too_large',
            payload_size => length($json),
            status       => 413,
        },
    );

    return 1;
}

sub _telemetry {
    my ( $self, $event_type, $metadata ) = @_;

    return $self->gp_security_telemetry->record( $event_type, $metadata );
}

sub _channel_type {
    my ($channel) = @_;

    return 'unknown'
      if !defined $channel || $channel !~ /\A ([a-z][a-z0-9_]*) [:]/msx;

    return $1;
}

1;
