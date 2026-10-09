# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Bootstrap::I18N;

use v5.40;

use GPForum::Bootstrap::UI;
use GPForum::Service::I18N;

our $VERSION = '0.001';

sub register ( $, %input ) {
    my $application = $input{application};
    my $config      = $input{config};

    return GPForum::Bootstrap::UI->register(
        application      => $application,
        default_theme    => $config->default_theme,
        default_timezone => $config->default_timezone,
        i18n             => GPForum::Service::I18N->new(
            default_locale => $config->default_locale,
        ),
    );
}

1;
