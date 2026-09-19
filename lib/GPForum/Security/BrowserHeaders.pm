package GPForum::Security::BrowserHeaders;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub apply {
    my ( $self, $controller ) = @_;

    my $headers = $controller->res->headers;

    $headers->header( 'X-Content-Type-Options' => 'nosniff' );
    $headers->header( 'X-Frame-Options'        => 'DENY' );
    $headers->header( 'Referrer-Policy' => 'strict-origin-when-cross-origin' );
    $headers->header( 'Permissions-Policy' =>
          'camera=(), microphone=(), geolocation=(), payment=()' );
    $headers->content_security_policy( $self->content_security_policy );

    return;
}

sub content_security_policy {
    my ($self) = @_;

    return join q{; }, @{ $self->directives };
}

sub directives {
    return [
        q{default-src 'self'},
        q{script-src 'self'},
        q{style-src 'self'},
        q{img-src 'self' data:},
        q{font-src 'self'},
        q{connect-src 'self'},
        q{base-uri 'self'},
        q{form-action 'self'},
        q{frame-ancestors 'none'},
        q{object-src 'none'},
    ];
}

1;
