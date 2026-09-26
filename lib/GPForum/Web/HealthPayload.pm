# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::HealthPayload;

use strict;
use warnings;
use feature 'signatures';

use Const::Fast;

our $VERSION = '0.001';

const my $HTTP_OK                  => 200;
const my $HTTP_SERVICE_UNAVAILABLE => 503;
const my %STATUS_CODE_FOR => (
    ok       => $HTTP_OK,
    degraded => $HTTP_OK,
    fail     => $HTTP_SERVICE_UNAVAILABLE,
);

sub live ( $, %input ) {
    return {
        status => 'ok',
        check  => 'live',
        time   => $input{clock}->now_iso8601,
    };
}

sub ready_status_code ( $, $status ) {
    return $STATUS_CODE_FOR{$status}
      if exists $STATUS_CODE_FOR{$status};

    return $HTTP_SERVICE_UNAVAILABLE;
}

sub summary ( $, %input ) {
    my $runtime  = $input{runtime};
    my $profile  = $runtime->os_profile;
    my $settings = $runtime->os_feature_settings;

    return {
        status       => 'ok',
        application  => 'GPForum',
        environment  => $input{config}->environment,
        runtime      => $runtime->as_hash,
        os           => $profile->snapshot,
        os_features  => $profile->feature_snapshot($settings),
        os_sockets   => $profile->socket_snapshot($settings),
        os_processes => $profile->process_snapshot($settings),
        time         => $input{clock}->now_iso8601,
    };
}

1;
