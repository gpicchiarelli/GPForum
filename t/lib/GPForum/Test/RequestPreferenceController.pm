package GPForum::Test::RequestPreferenceController;

use strict;
use warnings;

use Mojo::Base -base;
use Mojo::Message::Request;

our $VERSION = '0.001';

has accept_header => undef;
has format        => undef;

sub param {
    my ( $self, $name ) = @_;

    return $name eq 'format' ? $self->format : undef;
}

sub req {
    my ($self) = @_;

    my $request       = Mojo::Message::Request->new;
    my $accept_header = $self->accept_header;
    if ( defined $accept_header ) {
        $request->headers->accept($accept_header);
    }

    return $request;
}

1;
