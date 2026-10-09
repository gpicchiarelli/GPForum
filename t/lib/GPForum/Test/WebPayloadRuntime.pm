# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::WebPayloadRuntime;

use Mojo::Base -base;
use v5.40;

use GPForum::Test::WebPayloadProfile;

our $VERSION = '0.001';

# The runtime the health summary reads: four web processes and a fixed OS
# profile, so the payload it builds is stable.
sub as_hash {
    return { web_processes => 4 };
}

sub os_profile {
    return GPForum::Test::WebPayloadProfile->new;
}

sub os_feature_settings {
    return { enabled => 1 };
}

1;
