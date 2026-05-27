package GPForum::Bootstrap::Security;

use strict;
use warnings;

our $VERSION = '0.001';

sub register {
    my ( undef, %input ) = @_;

    my $application = $input{application};
    my $config      = $input{config};

    $application->sessions->samesite('Lax');
    $application->sessions->secure(
        $config->environment eq 'production' ? 1 : 0 );

    $application->hook(
        after_dispatch => sub {
            my ($controller) = @_;

            _set_browser_security_headers($controller);
        }
    );

    return;
}

sub _set_browser_security_headers {
    my ($controller) = @_;

    my $headers = $controller->res->headers;

    $headers->header( 'X-Content-Type-Options' => 'nosniff' );
    $headers->header( 'X-Frame-Options'        => 'DENY' );
    $headers->header( 'Referrer-Policy' => 'strict-origin-when-cross-origin' );
    $headers->header( 'Permissions-Policy' =>
          'camera=(), microphone=(), geolocation=(), payment=()' );
    $headers->content_security_policy(
        join q{; },
        q{default-src 'self'},
        q{base-uri 'self'},
        q{form-action 'self'},
        q{frame-ancestors 'none'},
        q{object-src 'none'},
    );

    return;
}

1;
