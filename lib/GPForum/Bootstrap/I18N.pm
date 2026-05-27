package GPForum::Bootstrap::I18N;

use strict;
use warnings;

use GPForum::Bootstrap::UI;
use GPForum::Service::I18N;

our $VERSION = '0.001';

sub register {
    my ( undef, %input ) = @_;

    my $application = $input{application};
    my $config      = $input{config};

    return GPForum::Bootstrap::UI->register(
        application => $application,
        i18n        => GPForum::Service::I18N->new(
            default_locale => $config->default_locale,
        ),
    );
}

1;
