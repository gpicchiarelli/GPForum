# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::AdminRuntimeStatus;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# Stands in for the readiness check and the metrics snapshot the admin
# console reads: a healthy database, one request observed, one pending
# outbox message.
sub check {
    return {
        status => 'ok',
        checks => [ { name => 'database', status => 'ok' } ],
    };
}

sub collect {
    return {
        db_query_stats => { requests_observed => 1 },
        outbox         => { pending           => 1 },
        runtime        => { mode              => 'test' },
    };
}

1;
