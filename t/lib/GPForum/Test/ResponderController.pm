package GPForum::Test::ResponderController;

use strict;
use warnings;

use Mojo::Base 'GPForum::Test::RequestPreferenceController';

our $VERSION = '0.001';

has csrf_error      => 0;
has last_render     => undef;
has session_user_id => undef;

sub render {
    my ( $self, %args ) = @_;

    $self->last_render( \%args );
    return \%args;
}

sub session {
    my ( $self, $name ) = @_;

    if ( $name eq 'user_id' ) {
        return $self->session_user_id;
    }

    return;
}

sub gp_public_http_cache {
    my ($self) = @_;

    return $self;
}

sub validation {
    my ($self) = @_;

    return $self;
}

sub csrf_protect {
    my ($self) = @_;

    return $self;
}

sub has_error {
    my ( $self, $name ) = @_;

    if ( ( $name || q{} ) eq 'csrf_token' ) {
        return $self->csrf_error ? 1 : 0;
    }

    return 0;
}

1;
