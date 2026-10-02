# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SlotLimitConfig;

use strict;
use warnings;

use Mojo::Base 'GPForum::Config';

our $VERSION = '0.001';

# A configuration that carries the replication slot limit readiness reads,
# whether or not GPForum::Config has the setting yet.
has replication_slot_max_retained_bytes => undef;

1;
