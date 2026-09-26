# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::RealtimeAccess;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;
use Mojo::JSON qw(encode_json);
use Mojo::URL;

use GPForum::Web::Access;

our $VERSION = '0.001';

const my $MAX_MESSAGE_BYTES => 2_048;
const my $CONNECT_LIMIT     => 30;
const my $SUBSCRIBE_LIMIT   => 120;
const my $WINDOW_SECONDS    => 60;
const my $ACTION_CONNECT    => 'realtime.connect';
const my $ACTION_SUBSCRIBE  => 'realtime.subscribe';
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_TOO_MANY     => 429;
const my $AUTH_REQUIRED     => 'Authentication required';
const my $ORIGIN_DENIED     => 'Origin denied';
const my $TOO_MANY_CONNECT  => 'Too many realtime connections';
const my %ACTION_LIMIT_FOR => (
    'realtime.connect'   => $CONNECT_LIMIT,
    'realtime.subscribe' => $SUBSCRIBE_LIMIT,
);

has access => sub { return GPForum::Web::Access->new; };

sub origin_allowed ( $self, $controller ) {
    my $origin = $controller->req->headers->header('Origin');
    if ( !$self->access->has_text($origin) ) {
        return 1;
    }

    return $self->_origin_matches( $controller, $origin );
}

sub request_origin ( $, $controller ) {
    my $base   = $controller->req->url->base;
    my $scheme = $base->scheme || 'http';
    my $host   = $controller->req->headers->host || $base->host || q{};

    return join q{://}, $scheme, $host;
}

sub configured_origin ( $self, $public_base_url ) {
    my $url = Mojo::URL->new($public_base_url);

    return join q{://}, $url->scheme || 'http', $self->_origin_host($url);
}

sub payload_bytes ( $, $message ) {
    my $json = eval { return encode_json( $message || {} ); };
    if ( !defined $json ) {
        return 0;
    }

    return length $json;
}

sub payload_too_large ( $self, $message ) {
    return $self->payload_bytes($message) > $MAX_MESSAGE_BYTES ? 1 : 0;
}

sub write_rate_input ( $self, $input ) {
    return {
        action         => $input->{action},
        actor_id       => $input->{actor_id},
        limit          => $self->write_limit_for( $input->{action} ),
        scope          => 'user',
        window_seconds => $WINDOW_SECONDS,
    };
}

sub write_limit_for ( $, $action ) {
    if ( exists $ACTION_LIMIT_FOR{$action} ) {
        return $ACTION_LIMIT_FOR{$action};
    }

    return $CONNECT_LIMIT;
}

sub connect_action {
    return $ACTION_CONNECT;
}

sub subscribe_action {
    return $ACTION_SUBSCRIBE;
}

sub origin_denied {
    return {
        status => $HTTP_FORBIDDEN,
        text   => $ORIGIN_DENIED,
    };
}

sub authentication_required {
    return {
        status => $HTTP_UNAUTHORIZED,
        text   => $AUTH_REQUIRED,
    };
}

sub too_many_connections {
    return {
        status => $HTTP_TOO_MANY,
        text   => $TOO_MANY_CONNECT,
    };
}

sub is_subscribe ( $, $message ) {
    if ( !$message ) {
        return 0;
    }

    my $type = $message->{type} || q{};
    return $type eq 'subscribe' ? 1 : 0;
}

sub channel_type ( $, $channel ) {
    if ( !defined $channel ) {
        return 'unknown';
    }

    return _parsed_channel_type($channel);
}

sub _origin_matches ( $self, $controller, $origin ) {
    if ( $origin eq $self->request_origin($controller) ) {
        return 1;
    }
    if ( $origin eq
        $self->configured_origin( $controller->gp_config->public_base_url ) )
    {
        return 1;
    }

    return 0;
}

sub _origin_host ( $, $url ) {
    my $host = $url->host || q{};
    if ( defined $url->port ) {
        $host .= q{:} . $url->port;
    }

    return $host;
}

sub _parsed_channel_type ($channel) {
    if ( $channel =~ /\A ([[:lower:]] [[:lower:][:digit:]_]*) [:] /msx ) {
        return $1;
    }

    return 'unknown';
}

1;

__END__

=head1 NAME

GPForum::Web::RealtimeAccess - Websocket handshake and payload decisions.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $access = GPForum::Web::RealtimeAccess->new;
    if ( !$access->origin_allowed($controller) ) {
        return $controller->render( text => 'Origin denied', status => 403 );
    }

=head1 DESCRIPTION

Owns origin matching, subscribe-message shape, payload size, channel-type
parsing, C<user>-scope connect/subscribe rate-limit hashes, and plaintext
handshake texts for the realtime websocket. It does not call the rate
limiter, render HTTP errors, send frames, or record telemetry.
L<GPForum::Controller::Realtime> keeps those responsibilities.

=head1 SUBROUTINES/METHODS

=head2 origin_allowed

True when the Origin header is missing or matches the request or configured
public origin.

=head2 request_origin

Builds the request origin from scheme and Host.

=head2 configured_origin

Builds the configured origin from the public base URL.

=head2 payload_bytes

JSON-encodes a websocket message and returns its byte length. Failed encodes
return C<0>.

=head2 payload_too_large

True when the JSON payload exceeds the realtime message limit.

=head2 write_rate_input

Returns the C<user>-scope rate-limit arguments for a realtime action.

=head2 write_limit_for

Returns 30 for C<realtime.connect>, 120 for C<realtime.subscribe>, and 30
for any other action.

=head2 connect_action

Returns C<realtime.connect>.

=head2 subscribe_action

Returns C<realtime.subscribe>.

=head2 origin_denied

Returns the plaintext Origin-denied handshake payload.

=head2 authentication_required

Returns the plaintext authentication handshake payload.

=head2 too_many_connections

Returns the plaintext connect-limit and quota handshake payload.

=head2 is_subscribe

True when the message type is C<subscribe>.

=head2 channel_type

Returns the channel type prefix, or C<unknown>.

=head1 DIAGNOSTICS

These methods return booleans, byte lengths, channel-type strings, rate-limit
hashes, or plaintext handshake payloads. HTTP and websocket error rendering
stays in the realtime controller.

=head1 CONFIGURATION AND ENVIRONMENT

C<configured_origin> reads the public base URL supplied by the caller.

=head1 DEPENDENCIES

Uses L<GPForum::Web::Access>, L<Mojo::JSON>, and L<Mojo::URL>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not call the rate limiter or hub; those stay on the controller.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
