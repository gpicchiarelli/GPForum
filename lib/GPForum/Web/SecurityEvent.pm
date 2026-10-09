# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::SecurityEvent;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Web::Guard;

our $VERSION = '0.001';

const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_TOO_MANY     => 429;

# The route the event happened on; 'unknown' when there is none to name, as for
# a controller built outside a request, which has no current_route helper.
sub record_event ( $self, $controller, $event_type, $metadata ) {
    my $route;
    try {
        $route = $controller->current_route;
    }
    catch ($error) {
        $route = undef;
    };

    return $controller->gp_security_telemetry->record( $event_type,
        { %{$metadata}, route => $route || 'unknown' } );
}

sub csrf_failure ( $self, $controller ) {
    $self->record_event( $controller, 'csrf_failure',
        { status => $HTTP_FORBIDDEN } );

    return GPForum::Web::Guard->new->csrf_failure($controller);
}

sub unauthorized ( $self, $controller ) {
    $self->record_event( $controller, 'auth_denial',
        { status => $HTTP_UNAUTHORIZED } );

    return GPForum::Web::Guard->new->unauthorized($controller);
}

sub forbidden ( $self, $controller, $input = undef ) {
    $self->record_event( $controller, 'auth_denial',
        { reason => 'forbidden', status => $HTTP_FORBIDDEN } );

    return GPForum::Web::Guard->new->forbidden( $controller, $input );
}

sub rate_limited ( $self, $controller ) {
    $self->record_event( $controller, 'rate_limit_hit',
        { status => $HTTP_TOO_MANY } );

    return GPForum::Web::Guard->new->rate_limited($controller);
}

1;

__END__

=head1 NAME

GPForum::Web::SecurityEvent - Records a security event on the request's
route, and renders the refusals that record one.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $events = GPForum::Web::SecurityEvent->new;
    return $events->csrf_failure($controller) if $csrf_invalid;
    $events->record_event( $controller, 'suspended_user_block',
        { action => $action, status => 403 } );

=head1 DESCRIPTION

The admin, forum, identity, moderation, notification and privacy controllers
each record the same security events: a CSRF failure, an authentication or
permission denial, a rate-limit hit. This object records them through the
C<gp_security_telemetry> helper, adding the route the request matched, and
renders the refusal through L<GPForum::Web::Guard>, so each event has one
definition of its type and metadata.

=head1 SUBROUTINES/METHODS

=head2 record_event

Records C<$event_type> with the metadata hash plus C<route>: the controller's
current route, or C<unknown> when it has none or cannot name one.

=head2 csrf_failure

Records C<csrf_failure> with status 403 and renders the CSRF failure.

=head2 unauthorized

Records C<auth_denial> with status 401 and renders the authentication-required
error.

=head2 forbidden

Records C<auth_denial> with reason C<forbidden> and status 403 and renders the
permission-denied error. An optional payload hash overrides the message, as in
L<GPForum::Web::Guard/forbidden>.

=head2 rate_limited

Records C<rate_limit_hit> with status 429 and renders the too-many-requests
error.

=head1 DIAGNOSTICS

A telemetry failure propagates to the caller, as it did when each controller
recorded its own events.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, L<GPForum::Web::Guard>, and the controller's
C<gp_security_telemetry> helper.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The identity controllers render their own CSRF and rate-limit pages, so they
use only C<record_event>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
