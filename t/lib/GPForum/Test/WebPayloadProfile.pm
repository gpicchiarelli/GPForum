# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::WebPayloadProfile;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# An OS profile whose snapshots are one fixed key each.
sub snapshot {
    return { kernel => 'test-kernel' };
}

sub feature_snapshot {
    return { feature => 'ok' };
}

sub socket_snapshot {
    return { sockets => 'ok' };
}

sub process_snapshot {
    return { processes => 'ok' };
}

1;
