# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SmallHostConfig;

use Mojo::Base 'GPForum::Config', -signatures;
use v5.40;

our $VERSION = '0.001';

# A configuration on a host whose CPUs carry two web processes: one CPU at
# the default two a CPU.
sub automatic_web_processes ($self) {
    return 2;
}

1;
