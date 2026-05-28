package GPForum::Bootstrap::Security;

use strict;
use warnings;

use GPForum::Security::BrowserHeaders;

our $VERSION = '0.001';

sub register {
    my ( undef, %input ) = @_;

    my $application = $input{application};
    my $config      = $input{config};
    my $headers     = GPForum::Security::BrowserHeaders->new;

    $application->sessions->samesite('Lax');
    $application->sessions->secure(
        $config->environment eq 'production' ? 1 : 0 );

    $application->hook(
        after_dispatch => sub {
            my ($controller) = @_;

            $headers->apply($controller);
        }
    );

    return;
}

1;
