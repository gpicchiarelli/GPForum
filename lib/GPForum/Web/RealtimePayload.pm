package GPForum::Web::RealtimePayload;

use strict;
use warnings;

our $VERSION = '0.001';

sub connected {
    my ( undef, %input ) = @_;

    return {
        type          => 'realtime.connected',
        connection_id => $input{connection_id},
        fallback      => $input{fallback},
    };
}

sub subscribed {
    my ( undef, %input ) = @_;

    return {
        type    => 'subscribed',
        channel => $input{channel},
    };
}

sub error {
    my ( undef, %input ) = @_;

    return {
        type   => 'error',
        reason => $input{reason},
    };
}

1;
