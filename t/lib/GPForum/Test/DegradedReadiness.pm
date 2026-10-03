# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::DegradedReadiness;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

# A degraded report carrying what an anonymous client must not read: a
# replication slot name, an error text and the runtime profile.
sub check {
    return {
        status => 'degraded',
        checks => [
            { name => 'database', status => 'ok' },
            {
                name   => 'replication_slots',
                status => 'degraded',
                error  => 'slot standby_secret_slot retains too much WAL',
                report => { problems => ['standby_secret_slot is inactive'] },
            },
        ],
        environment => 'production',
        runtime     => { worker_processes => 2 },
        timestamp   => '2026-05-23T12:00:00Z',
    };
}

1;
