# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::Responder;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

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
