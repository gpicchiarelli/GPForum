package GPForum::Security::BrowserHeaders;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $HSTS_MAX_AGE => 31_536_000;

has include_hsts => sub { return 0; };

sub apply {
    my ( $self, $controller ) = @_;

    my $headers = $controller->res->headers;

    $headers->header( 'X-Content-Type-Options' => 'nosniff' );
    $headers->header( 'X-Frame-Options'        => 'DENY' );
    $headers->header( 'Referrer-Policy' => 'strict-origin-when-cross-origin' );
    $headers->header( 'Permissions-Policy' =>
          'camera=(), microphone=(), geolocation=(), payment=()' );
    $headers->content_security_policy( $self->content_security_policy );
    $self->_apply_hsts($headers);

    return;
}

sub content_security_policy {
    my ($self) = @_;

    return join q{; }, @{ $self->directives };
}

sub hsts_policy {
    return 'max-age=' . $HSTS_MAX_AGE . '; includeSubDomains';
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

sub _apply_hsts {
    my ( $self, $headers ) = @_;

    if ( !$self->include_hsts ) {
        return;
    }

    $headers->header( 'Strict-Transport-Security' => $self->hsts_policy );

    return;
}

1;
