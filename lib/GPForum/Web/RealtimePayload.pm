# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::RealtimePayload;

use strict;
use warnings;
use feature 'signatures';

our $VERSION = '0.001';

sub connected ( $, %input ) {
    return {
        type          => 'realtime.connected',
        connection_id => $input{connection_id},
        fallback      => $input{fallback},
    };
}

sub subscribed ( $, %input ) {
    return {
        type    => 'subscribed',
        channel => $input{channel},
    };
}

sub error ( $, %input ) {
    return {
        type   => 'error',
        reason => $input{reason},
    };
}

1;
