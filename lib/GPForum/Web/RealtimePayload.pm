# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::RealtimePayload;

use v5.40;

our $VERSION = '0.001';

sub connected ( $, %input ) {
    return {
        type          => 'realtime.connected',
        connection_id => $input{connection_id},
        fallback      => $input{fallback},
    };
}

sub subscribed ( $, %input ) {
    return {
        type    => 'subscribed',
        channel => $input{channel},
    };
}

sub error ( $, %input ) {
    return {
        type   => 'error',
        reason => $input{reason},
    };
}

1;

__END__

=head1 NAME

GPForum::Web::RealtimePayload - The JSON messages the realtime socket sends to a client.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $ws->send(
        {
            json => GPForum::Web::RealtimePayload->connected(
                connection_id => $connection_id,
                fallback      => $hub->fallback_state,
            ),
        }
    );
    $ws->send(
        { json => GPForum::Web::RealtimePayload->subscribed( channel => $channel ) }
    );
    $ws->send(
        { json => GPForum::Web::RealtimePayload->error( reason => $reason ) } );

=head1 DESCRIPTION

Holds the shape of the three control messages that
L<GPForum::Controller::Realtime> sends over the WebSocket: the greeting
after the connection opens, the acknowledgement of a subscription and an
error. Each is a plain hash reference with a C<type> key; the controller
encodes it as JSON.

=head1 SUBROUTINES/METHODS

=head2 connected

Class method. Takes key/value pairs C<connection_id> and C<fallback> (the
hub's fallback state). Returns
C<< { type => 'realtime.connected', connection_id => ..., fallback => ... } >>.

=head2 subscribed

Class method. Takes C<channel>. Returns
C<< { type => 'subscribed', channel => ... } >>.

=head2 error

Class method. Takes C<reason>. Returns
C<< { type => 'error', reason => ... } >>.

=head1 DIAGNOSTICS

None. Missing arguments come back as undefined values.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None beyond core Perl.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
