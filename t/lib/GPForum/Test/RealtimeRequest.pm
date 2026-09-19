package GPForum::Test::RealtimeRequest;

use strict;
use warnings;

use Mojo::Base -base;
use Mojo::Message::Request;
use Mojo::URL;

our $VERSION = '0.001';

has host            => 'forum.example.test';
has origin          => undef;
has public_base_url => 'https://forum.example.test';
has scheme          => 'https';

sub req {
    my ($self) = @_;

    my $request = Mojo::Message::Request->new;
    $request->url->base(
        Mojo::URL->new( join q{://}, $self->scheme, $self->host ) );
    $request->headers->host( $self->host );
    $self->_apply_origin($request);

    return $request;
}

sub gp_config {
    my ($self) = @_;

    return $self;
}

sub _apply_origin {
    my ( $self, $request ) = @_;

    if ( defined $self->origin ) {
        $request->headers->header( Origin => $self->origin );
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Test::RealtimeRequest - Fake websocket handshake request.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $controller = GPForum::Test::RealtimeRequest->new(
        origin => 'https://other.example.test',
    );

=head1 DESCRIPTION

Test double for C<Web::RealtimeAccess> origin matching: scheme, Host, Origin,
and public base URL.

=head1 SUBROUTINES/METHODS

=head2 req

Returns a Mojolicious request with base URL, Host, and optional Origin.

=head2 gp_config

Returns the same object so C<public_base_url> can be read as config.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Mojo::Message::Request> and L<Mojo::URL>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not emulate websocket upgrade headers.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
