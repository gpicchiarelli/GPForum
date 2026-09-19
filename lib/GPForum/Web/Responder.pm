package GPForum::Web::Responder;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

use GPForum::Web::RequestPreference;

our $VERSION = '0.001';

const my $DEFAULT_ERROR_TEMPLATE => 'forum/error';

sub wants_json {
    my ( $self, $controller ) = @_;

    return GPForum::Web::RequestPreference->wants_json($controller);
}

sub payload {
    my ( $self, $input ) = @_;

    if ( $self->wants_json( $input->{controller} ) ) {
        return $self->_json($input);
    }

    return $self->_html_payload($input);
}

sub error {
    my ( $self, $input ) = @_;

    if ( $self->wants_json( $input->{controller} ) ) {
        return $self->_json($input);
    }

    return $input->{controller}->render(
        template => $input->{template} || $DEFAULT_ERROR_TEMPLATE,
        %{ $input->{payload} },
        status => $input->{status},
    );
}

sub user_id {
    my ( undef, $controller ) = @_;

    return $controller->session('user_id');
}

sub _json {
    my ( undef, $input ) = @_;

    return $input->{controller}->render(
        json   => $input->{payload},
        status => $input->{status},
    );
}

sub _html_payload {
    my ( $self, $input ) = @_;

    if ( $input->{cache_options} ) {
        return $self->_cached_html($input);
    }

    return $input->{controller}->render(
        template => $input->{template},
        %{ $input->{payload} },
        status => $input->{status},
    );
}

sub _cached_html {
    my ( undef, $input ) = @_;

    return $input->{controller}->gp_public_http_cache->render(
        controller => $input->{controller},
        payload    => $input->{payload},
        status     => $input->{status},
        template   => $input->{template},
        %{ $input->{cache_options} },
    );
}

1;
