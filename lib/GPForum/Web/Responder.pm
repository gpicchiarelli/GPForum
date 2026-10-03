# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::Responder;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Web::ErrorPayload;
use GPForum::Web::RequestPreference;

our $VERSION = '0.001';

const my $DEFAULT_ERROR_TEMPLATE => 'forum/error';

sub wants_json ( $self, $controller ) {
    return GPForum::Web::RequestPreference->wants_json($controller);
}

sub payload ( $self, $input ) {
    if ( $self->wants_json( $input->{controller} ) ) {
        return $self->_json($input);
    }

    return $self->_html_payload($input);
}

sub error ( $self, $input ) {
    if ( $self->wants_json( $input->{controller} ) ) {
        return $self->_json($input);
    }

    # The payload's own status ('unauthorized') cannot reach the template:
    # `status` is the HTTP code to Mojolicious, and passing it last is what
    # makes the response a 401. The page reads error_page instead.
    return $input->{controller}->render(
        template => $input->{template} || $DEFAULT_ERROR_TEMPLATE,
        %{ $input->{payload} },
        error_page =>
          GPForum::Web::ErrorPayload->page( $input->{payload} || {} ),
        status => $input->{status},
    );
}

sub user_id ( $, $controller ) {
    return $controller->session('user_id');
}

sub _json ( $, $input ) {
    return $input->{controller}->render(
        json   => $input->{payload},
        status => $input->{status},
    );
}

sub _html_payload ( $self, $input ) {
    if ( $input->{cache_options} ) {
        return $self->_cached_html($input);
    }

    return $input->{controller}->render(
        template => $input->{template},
        %{ $input->{payload} },
        status => $input->{status},
    );
}

sub _cached_html ( $, $input ) {
    return $input->{controller}->gp_public_http_cache->render(
        controller => $input->{controller},
        payload    => $input->{payload},
        status     => $input->{status},
        template   => $input->{template},
        %{ $input->{cache_options} },
    );
}

1;

__END__

=head1 NAME

GPForum::Web::Responder - Render a payload as JSON or as an HTML page, by what the request asked for.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $responder = GPForum::Web::Responder->new;

    return $responder->payload(
        {
            controller => $controller,
            payload    => $payload,
            status     => 200,
            template   => 'forum/index',
        }
    );

    return $responder->error(
        {
            controller => $controller,
            payload    => { error => 'not found', status => 'not_found' },
            status     => 404,
        }
    );

=head1 DESCRIPTION

The access classes build a payload; this class decides how it leaves the
process. A request that wants JSON (see L<GPForum::Web::RequestPreference>)
gets the payload as JSON with the given HTTP status. Otherwise the payload's
keys go to the template's stash. When C<cache_options> are given, a page
render goes through the C<gp_public_http_cache> helper instead, with those
options. An error page also gets C<error_page>, built by
L<GPForum::Web::ErrorPayload>, because the payload's own C<status> key
(C<unauthorized>, say) would collide with the HTTP status Mojolicious reads
from C<status>.

=head1 SUBROUTINES/METHODS

=head2 wants_json

Takes a controller. Returns what L<GPForum::Web::RequestPreference/wants_json>
returns: 1 when the request asked for JSON, 0 otherwise.

=head2 payload

Takes a hash reference with C<controller>, C<payload> (a hash reference),
C<status>, C<template> and, optionally, C<cache_options>. Renders the payload
as JSON or through the template, or through the public HTTP cache when
C<cache_options> is set, and returns what the render returns.

=head2 error

Takes the same hash reference as C<payload>, without C<cache_options>;
C<template> defaults to C<forum/error>. Renders the payload as JSON, or the
template with the payload's keys, C<error_page> and the HTTP C<status>.
Returns what the render returns.

=head2 user_id

Takes a controller. Returns the C<user_id> from its session, or undef for an
anonymous request.

=head1 DIAGNOSTICS

Nothing of its own. C<payload> and C<error> expect C<payload> to be a hash
reference for an HTML render and die when it is not; render errors propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Web::ErrorPayload>, L<GPForum::Web::RequestPreference>.

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
